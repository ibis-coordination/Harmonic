# LLM Gateway — Stage 4 ingress (external access via `llm_gateway` API keys)

## Context

Stages 1–2 of the LLM gateway are live: internal agents' billed LLM calls relay through
the `llm-gateway` service (agent-runner image, `src/gateway/`), which resolves the payer
per call via `POST /internal/llm-gateway/select-payer` (`Internal::LLMGatewayController` →
`LLMGateway::PayerResolver`, pool-first via `LLM_POOL_CONFIG`, else the task run's stamped
billing customer). PR #483 shipped the 3-type ApiToken system: the `llm_gateway` token
type exists and is fully fenced — external agents can hold one, but **no endpoint accepts
it yet**.

This stage builds the ingress: an external agent presents its `llm_gateway` token as a
Bearer key against an OpenAI-compatible `POST /v1/chat/completions` on a public
`llm.<hostname>` edge, billed through the agent's existing funding mapping (pool config,
else its billing customer). Identity-keyed, not funding-keyed (decided 2026-07-09): the
token says who calls; the agent's own mapping says who pays.

Design source: `.claude/plans/harmonic-llm-gateway.md` Stage 4. Decisions confirmed
2026-07-10: **tenant-level flag** (mirrors `stripe_billing`), **RPM + daily request cap**
as the spend-ceiling stopgap (dollar ceilings wait for record-usage), **one PR**.

## Request path

```
OpenAI client (base_url=https://llm.harmonic.social/v1, api_key=<llm_gateway token>)
  → Caddy `llm.<hostname>` block: forwards ONLY /v1/* to llm-gateway:4500
    → gateway POST /v1/chat/completions
        1. body-size cap → 413; per-key rate limit (RPM + RPD, in-memory) → 429
        2. POST Rails /internal/llm-gateway/select-payer-for-token (HMAC, IP-restricted)
           body: { agent_token, model }
             - authenticate token cross-tenant by hash; must be llm_gateway type + active
             - re-scope thread to the token's tenant; check tenant `llm_gateway` flag
             - resolve payer: pool_customer_ids(agent) sample → else agent.billing_customer
             - map/validate model via StripeGatewayModelMapper
             - 200 { payer_customer_id, model } | 401 | 403 | 402 | 400
        3. non-200 → pass through verbatim (no LLM spend)
        4. rewrite body.model to mapped model; forward to Stripe AI Gateway with
           X-Stripe-Customer-ID
        5. stream upstream response bytes back verbatim (SSE and non-streaming, one path)
```

The internal relay (`POST /chat/completions` + `X-Harmonic-*` headers, no auth — network
isolation is its auth) is unchanged and unreachable from the edge: Caddy forwards only
`/v1/*`, and the handler routes the two paths separately.

## Rails changes

**`app/models/api_token.rb` — `ApiToken.authenticate_llm_gateway(token_string)`**
Cross-tenant lookup by token hash. The unguessable 256-bit hash IS the credential
(lookup = authentication), which is why this is safe pre-tenant — same character as User
auth. None of the four ApplicationRecord wrappers fit (no tenant id, no user, non-nil
thread tenant), so this is the one deliberate `unscoped` outside ApplicationRecord,
carrying the `# unscoped-allowed` marker + justification comment. Query:
`unscoped.where(token_hash:, deleted_at: nil, internal: false, token_type: "llm_gateway").first`
(`unscoped` drops BOTH the tenant default scope and ApiToken's own
`default_scope { where(internal: false) }`, hence re-adding `internal: false` — only
user-issued keys authenticate here). Caller checks `expired?` (matches existing
`.authenticate` convention where expiry is a call-site check).

**`app/controllers/internal/llm_gateway_controller.rb` — `select_payer_for_token`**
New action; `skip_before_action :resolve_tenant_from_subdomain` for it (routes have no
subdomain constraint — the before_action is the only coupling). IP restriction + HMAC
still apply. Flow:
- `ApiToken.authenticate_llm_gateway(params[:agent_token])` → 401 `invalid_token` if nil
  or `expired?` (body shaped like OpenAI errors: `{error: {message:, type:, code:}}` —
  the gateway passes these bodies through to the client verbatim).
- `Tenant.scope_thread_to_tenant` for the token's tenant (same helper
  `resolve_tenant_from_subdomain` uses), then load the agent user.
- 403 `feature_disabled` unless `tenant.feature_enabled?("llm_gateway")`.
- `LLMGateway::PayerResolver.resolve_for_agent(agent)` → 402 `not_funded` on
  ResolutionError.
- `StripeGatewayModelMapper.map(params[:model])` → 400 `unsupported_model` on
  UnmappedModelError.
- `token.token_used!`; 200 `{ payer_customer_id:, model: <mapped> }`.

**`app/services/llm_gateway/payer_resolver.rb` — `resolve_for_agent(agent)`**
Pool branch reuses `pool_customer_ids(agent.id)` (uniform-random sample, same log line);
else `agent.billing_customer` with the same funded checks as the task-run path (customer
present + `pricing_plan_subscription_id` present, else `ResolutionError` 402
`not_funded`). Extract the shared billing-customer check so the two resolve paths don't
diverge.

**`config/routes.rb`** — add `post 'select-payer-for-token'` to the existing
`internal/llm-gateway` scope.

**`config/feature_flags.yml`** — add `llm_gateway` entry (`app_enabled: true`,
`default_tenant: false`, `collective_level: false`). The tenant_admin settings UI is
generic over the yml (`tenant_admin_controller.rb:69`, `settings.html.erb:56`), so the
toggle appears with no UI code.

## Gateway changes (`agent-runner/src/gateway/`)

**`handler.ts`** — route on path:
- `GET /health` — unchanged.
- `POST /chat/completions` (and legacy `POST /` if currently accepted) — existing
  internal header flow, unchanged.
- `POST /v1/chat/completions` — new external flow (below). Anything else 404/405.

**New `ExternalRelay.ts`** (mirrors `Relay.ts` structure, Effect service deps:
Config, RailsHttp, StripeUpstream):
- Extract Bearer from `Authorization` → 401 OpenAI-style error if missing. Never log it.
- Body read with size cap (`GATEWAY_MAX_BODY_BYTES`, default 1 MB) → 413.
- Rate limit before any Rails/Stripe work: in-memory sliding-window per key
  (bucket key = SHA-256 of the bearer), `GATEWAY_EXTERNAL_RPM` (default 20) +
  `GATEWAY_EXTERNAL_RPD` (default 500) → 429 with `Retry-After`. Small standalone
  `RateLimiter` module (injectable clock for tests). Single-instance in-memory is
  fine — one gateway container; document that on the module.
- Parse body JSON minimally (`model`, detect `stream`) → 400 on unparseable JSON.
- Call `select-payer-for-token` via RailsHttp (10s timeout like the internal hop), Host =
  `HARMONIC_PRIMARY_SUBDOMAIN` (new env, default `app`; the action ignores the subdomain
  but Rails host authorization needs a real one). Non-200 → pass through verbatim.
- Rewrite `body.model` to the returned mapped model; forward to Stripe.
- **Streaming passthrough**: `StripeUpstream` gains `chatCompletionsStream` returning
  `{status, headers (content-type), body: ReadableStream}`; the handler pipes bytes to
  the response as they arrive. One code path serves `stream: true` (SSE) and
  non-streaming responses alike. Existing buffered `chatCompletions` stays for the
  internal relay.

**Observability** — log line per external call mirroring the internal one
(`event: "llm_request_external"`, token prefix only, model, status, duration); the
select-payer rejection warn mirrors `select_payer_rejected`.

**Compose (`docker-compose.yml`, `docker-compose.production.yml`)** — add
`HARMONIC_PRIMARY_SUBDOMAIN`, `GATEWAY_EXTERNAL_RPM/RPD`, `GATEWAY_MAX_BODY_BYTES` to
llm-gateway env; update the "no Caddy route" comment (now: edge-routed for `/v1/*` only).
`.env.example` documents the new vars.

## Edge

**`app/services/caddyfile_generator.rb`** — emit an `llm.<hostname>` block:

```
llm.<hostname> {
    handle /v1/* {
        reverse_proxy llm-gateway:4500
    }
    respond 403
}
```

Caddy and llm-gateway already share the `frontend` network in dev and prod. When the
`stripe` profile is off, the block 502s — acceptable (service intentionally absent).
Regenerate the committed `Caddyfile` (rake `caddyfile:generate`). Prod also needs DNS for
`llm.harmonic.social` — deploy note, not code.

## Rollout posture

Three independent off-switches: `stripe` compose profile (service exists at all),
tenant `llm_gateway` flag (default off — the ingress is inert everywhere until an admin
enables it), token revocation (gateway stateless — next call re-authenticates).
Deliberately deferred: dollar spend ceilings (needs record-usage persistence),
internal/external traffic isolation beyond path routing (flag is the off-ramp),
commitment-based consent enrollment (arrives with the real pool feature).

## Tests (red-green, in this order)

Rails (minitest):
- `test/models/api_token_test.rb` — `authenticate_llm_gateway`: finds across tenants;
  nil for wrong type / revoked / internal / unknown; expired token returned but
  `expired?` true.
- `test/services/llm_gateway/payer_resolver_test.rb` — `resolve_for_agent`: pool branch,
  billing-customer branch, `not_funded` when customer missing or unsubscribed.
- `test/controllers/internal/llm_gateway_controller_test.rb` (or existing integration
  file) — full matrix: 401 (missing/invalid/expired/wrong-type token), 403 flag off,
  402 not funded, 400 unsupported model, 200 pool payer, 200 billing-customer payer,
  thread re-scoped to the token's tenant, `last_used_at` bumped.

Gateway (vitest, existing patterns — fake `RelayRunner` for handler tests, Effect
`Layer.succeed` mocks for relay tests):
- `test/gateway/handler.test.ts` — path routing (internal untouched, `/v1/…` external,
  unknown 404), missing bearer 401.
- `test/gateway/ExternalRelay.test.ts` — size cap 413, rate limit 429 (+ RPD), malformed
  JSON 400, select-payer rejection passthrough, model rewrite, header forwarding,
  streaming passthrough with a fake `ReadableStream` upstream.
- `test/gateway/RateLimiter.test.ts` — window mechanics with injected clock.

## Verification

1. `docker compose exec web bundle exec rails test <the three Rails files>`; `cd
   agent-runner && npm test && npm run typecheck && npm run build`.
2. `srb tc`, rubocop, `./scripts/check-tenant-safety.sh` (the marker must pass).
3. Dev E2E: enable `llm_gateway` flag on the test tenant, mint an `llm_gateway` token for
   an external agent covered by `LLM_POOL_CONFIG`, regenerate Caddyfile, then from the
   host: `curl https://llm.harmonic.local/v1/chat/completions -H "Authorization: Bearer
   <token>" -d '{"model":"anthropic/claude-sonnet-4.6","messages":[…]}'` — expect
   Stripe's 400 balance error passed through verbatim (that error IS the relay-works
   proof while the Stripe blocker stands), and the same call with `"stream": true`
   streaming the error/SSE bytes. Negative checks: flag off → 403, revoked token → 401,
   rest-type token → 401, `POST /chat/completions` from outside → 403 (Caddy).
