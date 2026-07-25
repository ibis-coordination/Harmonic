# Show per-model rates in the internal-agent model selector

> **Shipped** with the per-model rates work (PRs #414/#421).

## Goal

Answer one question for the user choosing a model: **"how much will this cost
me?"** Show the per-model rate — the marked-up price from the Stripe rate card,
which is exactly what they pay. Nothing more.

In prod, LLM credits are pay-as-you-go token usage with no monthly minimum
(license fee verified absent — see note), so the input/output token rates are
the whole cost story.

## Data: `GatewayModelCatalog`

`app/services/gateway_model_catalog.rb` — returns each gateway model's price.

```
GatewayModelCatalog.prices
# => { "anthropic/claude-sonnet-4.6" => { input_per_million: "3.90", output_per_million: "19.50" }, … }
```

Pipeline (verified against the live API 2026-07-05, uses existing
`StripeService` v2 helper, `Stripe-Version: 2026-06-24.preview`):

```
STRIPE_PRICING_PLAN_ID
  → GET /v2/billing/pricing_plans/{id}/components   → component type=="rate_card" → rate_card.id
  → GET /v2/billing/rate_cards/{rcd}/rates?limit=100 (paginate)
      → per rate: meter_segment_conditions {model, token_type}; unit_amount (CENTS/token, marked up)
```

- **Display price** = `unit_amount × 1_000_000 / 100` dollars per million tokens.
  (Confirmed: sonnet-4.6 input `0.00039` → $3.90/M.)
- **Marked-up only.** The rate rows also carry `original_price_per_million_tokens`
  and `markup_percentage` — `GatewayModelCatalog` drops them. They never reach a
  view or the browser.
- **Cached** `Rails.cache.fetch("gateway_model_catalog", expires_in: 6.hours)`
  (rate card is account-global → one key). `rake billing:refresh_model_catalog`
  busts it.
- **Fails open.** Missing `STRIPE_PRICING_PLAN_ID` or any Stripe error → `{}`.
  The selector then shows models with no price rather than breaking.

## UI

Keep the existing model `<select>` exactly as it is — same models, no filtering.
Alongside it, render a small server-rendered price reference from the catalog:

```
Model  [ Claude Sonnet 4.6 ▼ ]

Model pricing (per million tokens)
  Claude Sonnet 4.6      input $3.90    output $19.50
  Claude Haiku 4.5       input $1.30    output $6.50
  GPT-5.1                input $1.63    output $13.00
  …
```

- One shared partial (`_model_pricing.html.erb`) rendered under the selector in
  both the new-agent form and settings. Server-rendered text — no JS, no client
  payload.
- A model in the `<select>` with no catalog price simply has no row (e.g. local
  Ollama models, or when the catalog is unavailable).
- Friendly display name (`anthropic/claude-sonnet-4.6` → "Claude Sonnet 4.6") for
  the label; the stored/submitted value stays the raw gateway name.
- Header line notes these are current prices (billing uses live rates at run
  time), so it reads as pricing info, not a locked quote.

**When `stripe_billing` is OFF** for the tenant, agent usage is operator-funded,
not billed to the user — the pricing block is omitted (showing token rates would
be misleading).

## Testing (red-green)

- `GatewayModelCatalog` against a captured rate-card JSON fixture: parses model
  rows, collapses input/output, computes per-M dollars, excludes base/markup
  fields. Cache hit/miss. Fail-open returns `{}` on error / missing env.
- Partial renders a price row per catalogued model; omits models without a
  price; omitted entirely when billing is off.

## Deliberately out of scope

Dropped to keep this to "show the rates": tier badges, filtering the model list
to billable-only, injecting an unavailable current value, a Stimulus rate line /
client-side catalog JSON. A standalone `/help/models` pricing page is a cheap
optional add (same catalog, one view) — include only if wanted; not required to
answer the question.

## Note: prod license fee

The March sandbox plan ("Harmonic Usage Test Plan 1") carried a $3/mo license
fee; prod's "LLM Tokens" plan is expected to have none (pay-as-you-go only).
Confirm on the live plan before relying on "token rates = full cost": check the
live plan's components for a `license_fee` with a non-zero `unit_amount`, or that
the smoke-test customer was charged only $3 (identity) + $5 (credits). If a fee
is ever added, this display must include it.
