#!/usr/bin/env bash
#
# Stripe setup for Harmonic billing (Layer 1 subscriptions + Layer 2 LLM credits).
#
# Creates or verifies every Stripe resource the app needs and prints the env
# vars to set. Idempotent: resources are found by metadata/lookup_key/URL
# before anything is created, so re-running is always safe. Resources that
# Stripe only allows through the dashboard (restricted keys, the token-billing
# pricing plan) are verified when their env vars are set and printed as manual
# steps when they aren't.
#
# Usage:
#   STRIPE_SECRET_KEY=sk_live_... HOSTNAME=harmonic.social PRIMARY_SUBDOMAIN=www \
#     ./scripts/stripe-setup.sh
#   # or pass the app URL explicitly (overrides HOSTNAME/PRIMARY_SUBDOMAIN):
#   STRIPE_SECRET_KEY=sk_live_... ./scripts/stripe-setup.sh https://www.harmonic.social
#
# STRIPE_SECRET_KEY is used ONLY for this run, from your workstation. It is
# NOT one of the app's env vars and must never be deployed — the server only
# gets restricted keys (STRIPE_API_KEY, STRIPE_GATEWAY_KEY). The account
# secret key is needed here because restricted keys generally can't create
# webhook endpoints.
#
# The webhook URL is derived as https://$PRIMARY_SUBDOMAIN.$HOSTNAME (the
# app's canonical non-tenant host, same as the mailers use). Any subdomain
# the app serves would work — the webhook route skips tenant scoping — but
# the primary host is the stable choice.
#
# Optional env vars (verified when set, created/instructed when not):
#   STRIPE_CREDIT_PRODUCT_ID   product for LLM credit top-ups
#   STRIPE_PRICE_ID            $3/month identity subscription price
#   STRIPE_WEBHOOK_SECRET      (presence noted only — secrets can't be re-fetched)
#   STRIPE_PRICING_PLAN_ID     token-billing pricing plan (dashboard-only creation)
#   STRIPE_GATEWAY_KEY         AI gateway restricted key (dashboard-only creation)
#
set -euo pipefail

APP_URL="${1:-}"
if [ -z "$APP_URL" ] && [ -n "${HOSTNAME:-}" ] && [ -n "${PRIMARY_SUBDOMAIN:-}" ]; then
  APP_URL="https://${PRIMARY_SUBDOMAIN}.${HOSTNAME}"
fi
if [ -z "$APP_URL" ] || [ -z "${STRIPE_SECRET_KEY:-}" ]; then
  echo "Usage: STRIPE_SECRET_KEY=sk_live_... $0 https://your-primary-app-host"
  echo "   or: STRIPE_SECRET_KEY=sk_live_... HOSTNAME=... PRIMARY_SUBDOMAIN=... $0"
  exit 1
fi
APP_URL="${APP_URL%/}"
WEBHOOK_URL="$APP_URL/stripe/webhooks"
echo "App URL: $APP_URL (webhook endpoint: $WEBHOOK_URL)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
section() { echo -e "\n${CYAN}== $1 ==${NC}"; }
ok()      { echo -e "${GREEN}✓ $1${NC}"; }
warn()    { echo -e "${YELLOW}! $1${NC}"; }
fail()    { echo -e "${RED}✗ $1${NC}"; }

MANUAL_STEPS=()
ENV_LINES=()

api() { # method path [curl -d args...]
  local method="$1" path="$2"; shift 2
  curl -sS -X "$method" "https://api.stripe.com$path" -u "$STRIPE_SECRET_KEY:" "$@"
}

api_v2_get() { # path
  curl -sS "https://api.stripe.com$1" \
    -H "Authorization: Bearer $STRIPE_SECRET_KEY" \
    -H "Stripe-Version: 2025-09-30.preview"
}

json() { # extract field(s) from stdin: json 'expr using d'
  python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# --- Preflight -----------------------------------------------------------

section "Preflight"
probe_json=$(api GET /v1/products -G -d "limit=1")
probe_err=$(echo "$probe_json" | json "d.get('error',{}).get('message','')")
if [ -n "$probe_err" ]; then
  fail "Key rejected by Stripe (products read is required for setup): $probe_err"
  exit 1
fi
case "$STRIPE_SECRET_KEY" in
  sk_live_*|rk_live_*) mode="LIVE" ;;
  sk_test_*|rk_test_*) mode="TEST" ;;
  *) mode="UNKNOWN" ;;
esac
account_id=$(api GET /v1/account | json "d.get('id','')" 2>/dev/null || true)
ok "Authenticated${account_id:+ to account $account_id} ($mode mode)"
if [ "$mode" = "LIVE" ] && echo "$APP_URL" | grep -qE '\.local(host)?(:[0-9]+)?$'; then
  fail "Refusing to run LIVE-mode setup against $APP_URL — check HOSTNAME/PRIMARY_SUBDOMAIN (bash sets HOSTNAME to the machine name if you don't)."
  exit 1
fi
case "$STRIPE_SECRET_KEY" in
  rk_*) warn "Using a restricted key for setup; it needs write access to Products, Prices, and Webhook Endpoints. Prefer the account secret key (sk_...) for this one-time setup — it is never stored on the server." ;;
esac

# --- Credit product (Layer 2 top-ups) ------------------------------------

section "Credit product (STRIPE_CREDIT_PRODUCT_ID)"
if [ -n "${STRIPE_CREDIT_PRODUCT_ID:-}" ]; then
  name=$(api GET "/v1/products/$STRIPE_CREDIT_PRODUCT_ID" | json "d.get('name') or d.get('error',{}).get('message')")
  ok "Verified existing product $STRIPE_CREDIT_PRODUCT_ID ($name)"
  credit_product_id="$STRIPE_CREDIT_PRODUCT_ID"
else
  credit_product_id=$(api GET "/v1/products/search" --data-urlencode "query=metadata['harmonic_role']:'llm_credit_topup'" -G | json "d['data'][0]['id'] if d.get('data') else ''")
  if [ -n "$credit_product_id" ]; then
    ok "Found existing product by metadata: $credit_product_id"
  else
    credit_product_id=$(api POST /v1/products \
      -d "name=LLM Credits" \
      -d "metadata[harmonic_role]=llm_credit_topup" | json "d['id']")
    ok "Created product $credit_product_id"
  fi
fi
ENV_LINES+=("STRIPE_CREDIT_PRODUCT_ID=$credit_product_id")

# --- Identity subscription price (Layer 1) -------------------------------

section "Identity subscription price (STRIPE_PRICE_ID)"
if [ -n "${STRIPE_PRICE_ID:-}" ]; then
  amount=$(api GET "/v1/prices/$STRIPE_PRICE_ID" | json "d.get('unit_amount') or d.get('error',{}).get('message')")
  ok "Verified existing price $STRIPE_PRICE_ID (unit_amount: $amount)"
  price_id="$STRIPE_PRICE_ID"
else
  price_id=$(api GET /v1/prices -G -d "lookup_keys[]=harmonic-identity-monthly" | json "d['data'][0]['id'] if d.get('data') else ''")
  if [ -n "$price_id" ]; then
    ok "Found existing price by lookup_key: $price_id"
  else
    sub_product_id=$(api GET "/v1/products/search" --data-urlencode "query=metadata['harmonic_role']:'identity_subscription'" -G | json "d['data'][0]['id'] if d.get('data') else ''")
    if [ -z "$sub_product_id" ]; then
      sub_product_id=$(api POST /v1/products \
        -d "name=Harmonic billable identity" \
        -d "metadata[harmonic_role]=identity_subscription" | json "d['id']")
      ok "Created subscription product $sub_product_id"
    fi
    price_id=$(api POST /v1/prices \
      -d "product=$sub_product_id" \
      -d "unit_amount=300" \
      -d "currency=usd" \
      -d "recurring[interval]=month" \
      -d "lookup_key=harmonic-identity-monthly" | json "d['id']")
    ok "Created price $price_id (\$3.00/month)"
  fi
fi
ENV_LINES+=("STRIPE_PRICE_ID=$price_id")

# --- Webhook endpoint -----------------------------------------------------

section "Webhook endpoint (STRIPE_WEBHOOK_SECRET)"
webhooks_json=$(api GET /v1/webhook_endpoints -G -d "limit=100")
list_err=$(echo "$webhooks_json" | json "d.get('error',{}).get('message','')")
if [ -n "$list_err" ]; then
  fail "Could not list webhook endpoints (the check needs webhook read access): $list_err"
  MANUAL_STEPS+=("Verify the webhook endpoint manually (Dashboard → Developers → Webhooks): url $WEBHOOK_URL, events: checkout.session.completed, customer.subscription.updated, customer.subscription.deleted, invoice.payment_failed. Use 'Send test event' and confirm a 200 delivery.")
  existing_webhook="skip"
else
  # Match on trailing-slash-normalized URLs; surface near-misses (e.g. a
  # different subdomain) instead of silently creating a duplicate endpoint.
  existing_webhook=$(echo "$webhooks_json" | json "next((w['id'] for w in d.get('data',[]) if w.get('url','').rstrip('/')=='$WEBHOOK_URL'.rstrip('/')), '')")
  if [ -z "$existing_webhook" ]; then
    near_miss=$(echo "$webhooks_json" | json "next((f\"{w['id']} {w['url']}\" for w in d.get('data',[]) if w.get('url','').endswith('/stripe/webhooks')), '')")
    if [ -n "$near_miss" ]; then
      warn "No endpoint matches $WEBHOOK_URL exactly, but one exists at a different host: $near_miss"
      warn "If that host reaches the app, it works — the route is served on every subdomain. Not creating a duplicate."
      MANUAL_STEPS+=("Webhook URL mismatch: script expected $WEBHOOK_URL but found $near_miss. Either is fine if the host reaches the app — just ensure STRIPE_WEBHOOK_SECRET is that endpoint's signing secret, and verify with the dashboard's 'Send test event' (expect a 200 delivery).")
      existing_webhook="skip"
    fi
  fi
fi
if [ "$existing_webhook" = "skip" ]; then
  :
elif [ -n "$existing_webhook" ]; then
  ok "Webhook endpoint already exists for $WEBHOOK_URL ($existing_webhook)"
  if [ -n "${STRIPE_WEBHOOK_SECRET:-}" ]; then
    ok "STRIPE_WEBHOOK_SECRET is set (cannot be verified remotely — secrets are only shown at creation)"
    ENV_LINES+=("STRIPE_WEBHOOK_SECRET=<the value you already have>")
  else
    warn "Endpoint exists but you don't have its secret. Stripe never re-shows secrets:"
    warn "either roll it in the dashboard, or delete the endpoint and re-run this script."
    MANUAL_STEPS+=("Recover the webhook secret for $existing_webhook (Dashboard → Developers → Webhooks → roll secret), or delete the endpoint and re-run this script.")
  fi
else
  webhook_json=$(api POST /v1/webhook_endpoints \
    -d "url=$WEBHOOK_URL" \
    -d "enabled_events[]=checkout.session.completed" \
    -d "enabled_events[]=customer.subscription.updated" \
    -d "enabled_events[]=customer.subscription.deleted" \
    -d "enabled_events[]=invoice.payment_failed")
  webhook_id=$(echo "$webhook_json" | json "d.get('id','')")
  webhook_secret=$(echo "$webhook_json" | json "d.get('secret','')")
  if [ -n "$webhook_id" ]; then
    ok "Created webhook endpoint $webhook_id for $WEBHOOK_URL"
    ENV_LINES+=("STRIPE_WEBHOOK_SECRET=$webhook_secret")
  else
    fail "Webhook creation failed: $(echo "$webhook_json" | json "d.get('error',{}).get('message','unknown')")"
    MANUAL_STEPS+=("Webhook endpoint creation failed (see error above). Re-run with a key that has Webhook Endpoints write access, or create it in the dashboard: url $WEBHOOK_URL, events: checkout.session.completed, customer.subscription.updated, customer.subscription.deleted, invoice.payment_failed. Its signing secret is STRIPE_WEBHOOK_SECRET.")
  fi
fi

# --- Pricing plan (dashboard-only creation during preview) ----------------

section "Token-billing pricing plan (STRIPE_PRICING_PLAN_ID)"
plans_json=$(api_v2_get "/v2/billing/pricing_plans?limit=20")
if [ -n "${STRIPE_PRICING_PLAN_ID:-}" ]; then
  found=$(echo "$plans_json" | json "next((p['display_name'] for p in d.get('data',[]) if p['id']=='$STRIPE_PRICING_PLAN_ID' and p.get('active')), '')")
  if [ -n "$found" ]; then
    ok "Verified pricing plan $STRIPE_PRICING_PLAN_ID ($found, active)"
    ENV_LINES+=("STRIPE_PRICING_PLAN_ID=$STRIPE_PRICING_PLAN_ID")
  else
    fail "STRIPE_PRICING_PLAN_ID=$STRIPE_PRICING_PLAN_ID not found among active pricing plans"
    MANUAL_STEPS+=("Fix STRIPE_PRICING_PLAN_ID: it doesn't match any active pricing plan on this account.")
  fi
else
  echo "$plans_json" | json "'\n'.join(f\"  {p['id']}  {p['display_name']}  (active: {p['active']})\" for p in d.get('data',[])) or '  (none found)'"
  plan_count=$(echo "$plans_json" | json "len([p for p in d.get('data',[]) if p.get('active')])")
  if [ "$plan_count" = "0" ]; then
    MANUAL_STEPS+=("Create the pricing plan (dashboard-only during preview): Dashboard → Pricing plans → Create → 'Billing for LLM tokens' template. Select the models to offer and set the MARKUP PERCENTAGE (this is the pricing decision). Then set STRIPE_PRICING_PLAN_ID to its bpp_... id and re-run this script to verify.")
    warn "No active pricing plan found — see manual steps."
  else
    MANUAL_STEPS+=("Pick the pricing plan from the list above (or create a fresh one via the 'Billing for LLM tokens' template) and set STRIPE_PRICING_PLAN_ID, then re-run this script to verify.")
    warn "Pricing plan(s) exist but STRIPE_PRICING_PLAN_ID is not set — see manual steps."
  fi
fi

# --- Gateway key (dashboard-only creation) --------------------------------

section "AI gateway key (STRIPE_GATEWAY_KEY)"
if [ -n "${STRIPE_GATEWAY_KEY:-}" ]; then
  gw_status=$(curl -sS -o /dev/null -w '%{http_code}' https://llm.stripe.com/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $STRIPE_GATEWAY_KEY" \
    -d '{"model": "anthropic/claude-haiku-4.5", "messages": [{"role": "user", "content": "ping"}], "max_tokens": 1}')
  if [ "$gw_status" = "200" ]; then
    ok "Gateway key verified: llm.stripe.com returned 200 (unattributed test call, ~fraction of a cent)"
    ENV_LINES+=("STRIPE_GATEWAY_KEY=<the value you already have>")
  else
    fail "llm.stripe.com returned $gw_status — check the key's mode (live vs test) and its 'Billing: Meter events (write)' permission"
    MANUAL_STEPS+=("Fix STRIPE_GATEWAY_KEY: llm.stripe.com returned $gw_status.")
  fi
else
  MANUAL_STEPS+=("Create the gateway restricted key (dashboard-only): Dashboard → Developers → API keys → Create restricted key, permission 'Billing: Meter events' = Write, nothing else. Set it as STRIPE_GATEWAY_KEY (both Rails and agent-runner) and re-run this script to verify.")
  warn "STRIPE_GATEWAY_KEY not set — see manual steps."
fi

# --- Backend restricted key (dashboard-only creation) ----------------------

section "Backend restricted key (STRIPE_API_KEY)"
MANUAL_STEPS+=("Create the backend restricted key (dashboard-only): Dashboard → Developers → API keys → Create restricted key with: Customers (write), Checkout Sessions (write), Subscriptions (write), Invoices (write), Products (write), Credit grants (write), Credit balance summary (read), Customer portal (write), PaymentIntents (write), plus Billing v2 preview access for pricing-plan subscriptions (see docs/BILLING.md). Set it as STRIPE_API_KEY on Rails. Do NOT use the account secret key on the server.")
warn "Cannot be created via API — see manual steps."

# --- Summary ---------------------------------------------------------------

section "Environment variables"
echo "Set these on the production Rails app (and STRIPE_GATEWAY_KEY on the agent-runner too):"
echo
for line in "${ENV_LINES[@]}"; do echo "  $line"; done
echo "  STRIPE_MAX_TOPUP_CENTS=50000   # optional, default shown"

section "Manual steps (dashboard-only)"
if [ ${#MANUAL_STEPS[@]} -eq 0 ]; then
  ok "None — everything created or verified."
else
  i=1
  for step in "${MANUAL_STEPS[@]}"; do echo "  $i. $step"; i=$((i+1)); done
fi
echo
echo "Also (one-time, email): ask token-billing-team@stripe.com to enable zero-balance"
echo "request rejection for this account, so the gateway hard-stops usage at \$0."
echo
echo "After deploying the env vars, verify from the app server:"
echo "  bundle exec rails billing:gateway_health"
