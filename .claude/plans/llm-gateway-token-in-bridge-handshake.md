# LLM gateway token in the bridge handshake

## Goal

`harmonic-bridge add` exchanges a setup URL for an MCP token and a webhook
signing secret. Add an optional third credential: an `llm_gateway`-type API
token, so Harmonic can be the external agent's LLM provider — no provider key
on the agent's machine, revocation and metering in one place, and every
harness's manual LLM-credential step disappears. Larger effect: an external
agent on someone else's hardware becomes fundable by a collective's pool, the
same accountability story the built-in personas have.

The gateway side needs nothing: external ingress
(`https://llm.<HOSTNAME>/v1/chat/completions`, OpenAI-compatible, streaming,
per-key rate limits), token-type auth, pool-first payer resolution, and
server-side model defaulting all exist. This is handshake plumbing plus policy.

## Settled decisions

1. **Opt-in checkbox** on the "Connect harmonic-bridge" page, default off,
   stored on `HarmonicBridgeSetup`, shown only when the tenant has the
   `llm_gateway` flag. Attaching prepaid balances to a machine the operator
   controls is an explicit choice.
2. **No structural payer → omit, don't fail.** Gate on structure (funding pool
   or billing customer with a prepaid subscription), never on transient
   balance. The handshake succeeds without the token and says why in a status
   field.
3. **Dry balance mid-wake** is the gateway's open zero/low-balance
   notification work (2.2), not this increment. The wake fails with a 402 in
   the bridge log.
4. **Model:** chosen bridge-side, not on the wire (revised 2026-07-27,
   superseding "response carries the resolved default"). The setup page
   offers the tenant's `enabled_gateway_models` (fallback: platform default)
   as a selector that appends `--model <name>` to the generated commands;
   `add` writes it into the agent config as `harmonic_llm_model`. Without
   the flag, the `"default"` sentinel — resolved by the gateway per call —
   so a bare CLI add tracks the platform default. Page-generated commands
   are always explicit, preserving self-describing config where it matters.
5. **Billing quantity: non-issue** (verified). `billable_quantity` counts
   identities, never tokens; `redeem!` triggers no subscription sync.

## Scope

### Rails

1. Migration: `include_llm_token` boolean (default false, null false) and
   `llm_api_token_id` reference on `harmonic_bridge_setups`.
2. Setup-creation checkbox (`AiAgentBridgeSetupsController` + views). Copy
   states what it does: the machine gets a token that spends the agent's
   funding.
3. `PayerResolver.structurally_fundable?(agent)`: `funding_pool_id` present,
   or `resolved_billing_customer` with a `pricing_plan_subscription_id`. The
   resolver stays the single home for payer policy.
4. `redeem!`: when opted in and tenant flag on — if fundable, mint the
   `llm_gateway` token (scopes `ApiToken.read_scopes`; unused on the gateway
   path but presence-validated; 1-year expiry, same naming convention) and
   return `harmonic_llm_endpoint`, `harmonic_llm_token`, `harmonic_llm_model`;
   otherwise return `harmonic_llm_status` with the reason.
5. `revert_completion!` destroys both tokens. That is the whole teardown
   change: all failure paths funnel through it, and post-setup revocation
   (tokens page, suspension's delete-all sweep) is already token-count-agnostic.

### Bridge

6. `add.ts`: store the LLM token via the secrets backend (own secret ref);
   write `llm_endpoint` + `llm_model` + token ref into the agent config. On
   `harmonic_llm_status`, print it and continue.
7. Daemon: export `HARMONIC_BRIDGE_LLM_ENDPOINT` / `_MODEL` / resolved
   `_TOKEN` into the wake env when configured; absent otherwise.
8. Docs: bridge README (env table + trust-boundary note: the wake process can
   spend the agent's funding), `/help/self-hosting-agents`, `/help/api`.

Red-green per step: redeem permutations (opt-in × flag × fundable), teardown
destroys both, response shape; checkbox round-trip; add.ts stores/omits;
daemon env trio present/absent.

## Verification

On stickman (goose sprite): opt in, redo the handshake, map the wake env into
`OPENAI_HOST`/`OPENAI_API_KEY` by hand, confirm a wake completes a
gateway-billed call and the ledger row lands.

## Goose auto-wiring (added to scope 2026-07-27)

End goal: one-command sprite setup — checkbox + `setup-sprite --harness goose`
puts an agent up with zero knowledge of internals. Goose only; Claude Code
cannot consume the gateway (Anthropic wire format) and Codex wiring is
deferred.

8. `goose-harness` built-in: when the agent config carries the
   `harmonic_llm_*` keys (i.e. the handshake delivered the credential), the
   generated wake command maps them into goose's provider env with
   defer-to-operator semantics (`${GOOSE_PROVIDER:-openai}`,
   `${GOOSE_MODEL:-$HARMONIC_BRIDGE_LLM_MODEL}`,
   `${OPENAI_BASE_URL:-$HARMONIC_BRIDGE_LLM_ENDPOINT}`,
   `${OPENAI_API_KEY:-$HARMONIC_BRIDGE_LLM_TOKEN}`). Verified against goose
   source: `OPENAI_BASE_URL` with a `/v1` URL yields base path
   `v1/chat/completions`; explicit `OPENAI_HOST` env outranks it, so
   operator-set BYO env always wins. Without the keys, the wake command is
   unchanged.
9. `setup-sprite` goose readiness: ready when the agent config is
   gateway-wired OR the provider env is set; instructions mention both paths.
10. Copy: SPRITE_HARNESSES goose note, help-page harness table, checkbox
    hint, bridge README.

## Not in scope

- Codex/Claude Code auto-wiring (Codex worth adding later; Claude Code can't
  speak the OpenAI-compatible gateway at all).
- Zero/low-balance notifications (gateway 2.2).
- `harmonic-bridge remove` (open separately).

## Constraint

Harmonic-as-provider requires a `stripe_billing` tenant with the `llm_gateway`
flag and a funded payer; self-hosted Harmonic has no gateway —
[llm-gateway-without-billing.md](llm-gateway-without-billing.md) would remove
that. Bring-your-own-key keeps working in every harness, permanently; this is
an enhancement to setup, never the only path.
