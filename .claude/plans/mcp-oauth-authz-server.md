# MCP OAuth 2.1 Authorization Server

> **Status: deferred.** Phase 2 OAuth is on hold in favor of [mcp-client-connect-flow.md](mcp-client-connect-flow.md), which delivers the Connect-button UX without an authorization server by rendering per-harness install actions (deeplink, CLI command, or config snippet) prefilled with a freshly-minted `ApiToken`. Full OAuth becomes worth revisiting if/when third-party MCP-client connectivity, cross-tenant agent federation, regulated-industry procurement, or a spec-strict client that rejects manual config becomes a concrete demand. Until then this doc is reference material for what a full Phase 2 would look like; it is not the active plan.

Replace the paste-token UX with an OAuth 2.1 "Connect Claude" flow against a hosted authorization server on each tenant. After this lands, a Claude Desktop / Cursor / Claude Code user installs Harmonic's MCP server by clicking a button — no token copy-paste, no per-client config file edits, no token expiry surprise.

This is Phase 2 of [hosted-mcp-server.md](hosted-mcp-server.md). Phase 1 (Bearer `/mcp` + audit log + `mcp_only` + rate limits) and Phase 5 (agent-runner consolidation) are already in production. Phase 2 reuses every Phase 1 layer below the Bearer parse: capability gates, `McpToolCallLog`, rate limits, billing — all of it.

## Goal

Today's setup: agent owner creates an agent, copies a Bearer token, opens a JSON config file, pastes URL + token, restarts the client. Tomorrow: agent owner clicks "Connect Claude" in the agent's settings page; a browser opens to a Harmonic consent screen with the agent pre-selected; user approves; the client gets a token and reconnects automatically. No paste-token; no manual config.

The token still binds one Bearer credential to one agent identity to one client app — the Connect flow is just the issuance UX. Existing paste-token tokens keep working.

## Spec target

- **OAuth 2.1** `draft-ietf-oauth-v2-1-13`
- **RFC 8414** Authorization Server Metadata (`/.well-known/oauth-authorization-server`)
- **RFC 9728** Protected Resource Metadata (`/.well-known/oauth-protected-resource`)
- **RFC 8707** Resource Indicators — `resource` param required at `/authorize` and `/token`, `aud` claim audience-bound
- **RFC 7591** Dynamic Client Registration — fallback for clients that don't yet do CIMD
- **CIMD** `draft-ietf-oauth-client-id-metadata-document-00` — MCP-preferred path

MCP `2025-11-25` MUSTs the AS must satisfy: PKCE S256 (reject non-PKCE / non-S256), refresh-token rotation for public clients, exact-match redirect URI validation, HTTPS-only endpoints, `aud` claim bound to the canonical MCP URI, no token passthrough to upstream APIs.

## Background decision: Doorkeeper

Adopt `doorkeeper` 5.9.3 as the AS backend. It gives us PKCE, refresh rotation, the `/oauth/authorize` and `/oauth/token` controllers, introspection, revocation, and a clients table for free. It does NOT give us RFC 8414 metadata, RFC 9728 metadata, RFC 8707 `resource` param + audience binding, or CIMD — all custom code.

The alternative considered was `rodauth-oauth`, which ships RFC 8414 + 8707 built-in but is a Roda plugin embedded in a Rails app — heavier learning curve, smaller community. For an established Rails 8.1 codebase the pragmatic choice is Doorkeeper plus ~1-2 weeks of MCP-specific glue. The glue is mostly small additive controllers + a custom token generator + a CIMD client validator.

## Architectural decision: token unification

**Recommendation: OAuth-issued tokens write into the existing `ApiToken` model, not into `Doorkeeper::AccessToken`.**

Why: every layer below the Bearer parse already keys off `api_token_id` — `McpToolCallLog`, rate limits, billing, the `mcp_only` flag, the `last_used_at` indicator. Adding a parallel `Doorkeeper::AccessToken` path would require duplicating each one or a switch in `current_token`. The OAuth flow contributes new metadata (`act` = parent human, `aud` = MCP URI, `client_id` = which OAuth client) — those are new columns on `ApiToken`, not a parallel table.

Doorkeeper still owns its own tables for clients (`oauth_applications`), authorization grants (short-lived codes), and refresh tokens. What we override is the *access-token issuance* hook so that completing the `/oauth/token` exchange creates an `ApiToken` row (with `client_id`, `audience`, `parent_user_id` populated) and returns its plaintext as the OAuth response body.

This needs a spike (Step 1 below) to confirm Doorkeeper's `access_token_model` config or a controller override is the cleaner integration shape. If neither path works cleanly, fall back to running tables in parallel and unifying `current_token` to check both — flagged here, not committed to.

## Token-to-agent binding

Each OAuth token authenticates as exactly one agent identity. Preserves today's "1 token = 1 acting user" model; the OAuth Connect flow is the issuance UX.

- **`sub`** = the agent identity (what `/whoami` returns; what `CapabilityCheck` scopes to)
- **`act`** = parent human user (accountability; surfaced in audit chain and Connected Apps UI). Loose convention from RFC 8693.
- **`aud`** = canonical MCP URI for this tenant (`https://{subdomain}.harmonic.team/mcp`). Validated on every `/mcp` request per RFC 8707.
- **`scope`** = `read` / `write` (intersection with the agent's per-action capabilities — capabilities remain the fine-grained gate).
- **`client_id`** = which OAuth client (Claude Desktop, Cursor, Claude Code, etc.).

Consent screen authenticates the human, then shows an agent picker listing every agent they own plus a "+ Create new agent" inline option. The picked agent becomes the token's `sub`.

**One Connect flow = one token = one agent.** Connecting Claude Desktop to a second agent produces a separate token and a separate MCP server entry in the client's config. The client app is reusable; tokens are not.

**Immutable agent binding.** Refresh tokens inherit `sub`. You cannot mint a Meeting-Helper access token from a Research-Bot refresh token. To switch which agent a client acts as: revoke and re-Connect.

**Optional `harmonic_agent=<handle>` query param** on the authorize endpoint pre-selects an agent on the consent screen (still requires confirmation). Lets us deep-link "Connect as Meeting Helper" buttons from elsewhere in Harmonic.

## Steps

Each is independently shippable.

### Step 1 — Spike: Doorkeeper integration shape (no merge)

Throwaway branch. Goal: confirm whether `ApiToken` can be Doorkeeper's `access_token_model` cleanly, or whether the cleaner integration is overriding `Doorkeeper::TokensController#create` to write `ApiToken` after Doorkeeper validates the grant.

Output: a one-page note on the chosen integration shape, written into this plan, and a "throw away the branch" decision. **Plan is gated on this spike's outcome.**

### Step 2 — Install Doorkeeper, lock config to OAuth 2.1

- Add `doorkeeper` gem, run installer, generate migrations
- `force_pkce true`, `pkce_code_challenge_methods ['S256']`
- `use_refresh_token`, `revoke_previous_refresh_token_on_use`
- `grant_flows ['authorization_code']` (no ROPC, no implicit, no client_credentials yet)
- `access_token_expires_in 1.hour`, refresh expiry 60 days
- Disable Doorkeeper's default views (we render through our own layout)
- Mount Doorkeeper routes scoped to tenant subdomain (NOT auth subdomain — OAuth ASes per tenant)

Tests: smoke test that Doorkeeper rejects non-PKCE, rejects `plain` challenge method, rejects unrecognized grant types.

### Step 3 — RFC 8414 Authorization Server Metadata

- `GET /.well-known/oauth-authorization-server` returns the canonical JSON document
- `issuer`, `authorization_endpoint`, `token_endpoint`, `revocation_endpoint`, `introspection_endpoint`, `jwks_uri` (if JWT), `response_types_supported: ["code"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none", "client_secret_basic"]`, `scopes_supported: ["read", "write"]`, `client_id_metadata_document_supported: true`
- Per-tenant: each subdomain returns its own URLs

Tests: schema validation, per-tenant URL correctness, `code_challenge_methods_supported` present (clients refuse to proceed without it).

### Step 4 — RFC 9728 Protected Resource Metadata

- `GET /.well-known/oauth-protected-resource` returns `{resource, authorization_servers: [...], scopes_supported, bearer_methods_supported: ["header"], resource_documentation}`
- Update `/mcp` 401 response to include `WWW-Authenticate: Bearer resource_metadata="<URL>", scope="<scope>"` per the spec example

Tests: 401 header shape; PRM document validity; `authorization_servers` points at the same tenant's AS.

### Step 5 — RFC 8707 resource indicators + audience binding

The MUST item. Spec language: *"MCP servers MUST validate that access tokens were issued specifically for them as the intended audience, according to RFC 8707."*

- `Doorkeeper::PreAuthorization` accepts and persists `resource` param; rejects requests missing it
- `Doorkeeper::TokensController` echoes `resource` from grant → access token; rejects mismatched `resource` between authorize and token requests
- New `ApiToken.audience` column (string, indexed) populated from `resource`
- `Mcp::EndpointController` `before_action :validate_token_audience!` rejects tokens whose `audience` doesn't match the canonical MCP URI for the current tenant
- Reject tokens with no audience claim entirely (legacy paste-token `ApiToken`s have audience NULL — they're grandfathered via a separate `internal: true` or `paste_token: true` branch; **decide which during implementation**)

Tests: missing `resource` → 400; mismatched `resource` between authz and token → 400; `/mcp` with audience-mismatched token → 401; refresh token preserves audience.

### Step 6 — Custom access-token claims (`sub`, `act`, `aud`, `client_id`)

Per the spike outcome from Step 1:

- Either: custom token generator → writes `ApiToken` with `user_id` (sub), `parent_user_id` (act), `audience` (aud), `oauth_client_id` (client_id) populated
- Or: subclass `Doorkeeper::AccessToken` with `act`/`audience`/etc., and unify `current_token` to check both — only if Step 1 forces this fallback

Tests: every issued token has all four fields populated; capability check still scopes to `sub`; audit log shows `act` = parent human.

### Step 7 — Consent screen with agent picker

- `Doorkeeper::AuthorizationsController#new` overridden to render our own view
- View shows: client name + redirect URI hostname (per CIMD security guidance — prominent), requested scopes in plain English, agent picker (all agents the human owns), "+ Create a new agent" inline option, parent-agent relationship indicator
- Submitting picks the agent → grant created with `resource_owner_id` = picked agent's ID
- Pre-fill agent picker from optional `harmonic_agent=<handle>` query param
- "Connected Apps" management UI on the user's settings page — per-client revoke button (calls Doorkeeper's revoke for both access + refresh)

Tests: consent rejects an agent not owned by the authenticated human; per-tenant scoping prevents cross-tenant agent selection; revoke kills the token AND the refresh token; revoke event lands in `SecurityAuditLog`.

### Step 8 — Pre-registered clients (Claude Desktop, Claude Code, Cursor)

- Seed three `Doorkeeper::Application` rows with their `client_id`s, names, redirect URI patterns
- Pattern matching: per OAuth 2.1 §7.5.4, loopback redirects allow varying port at runtime for `http://127.0.0.1/callback` and `http://localhost/callback` — Doorkeeper supports loopback matching natively, confirm in spike
- These appear in the consent screen by friendly name; no DCR/CIMD trip required for them

Tests: an unregistered `client_id` triggers the CIMD/DCR fallback path; pre-registered Claude Desktop with a loopback redirect on port `54321` passes redirect URI validation.

### Step 9 — Client ID Metadata Documents (CIMD)

The MCP-preferred path for unknown clients. Self-contained custom code; isolate so the draft-00 wire format is easy to swap.

- `Mcp::OAuth::CimdValidator` service:
  1. Detect `client_id` that is `https://...`
  2. Fetch the URL server-side with **SSRF guards**: block private/loopback ranges (RFC 1918, 127/8, 169.254/16, IPv6 ULA), block redirects, enforce `Content-Type: application/oauth-client-id+jsonld` OR `application/json`, max body size 64 KiB, 5s timeout
  3. Validate document structure: `client_id` field equals the URL exactly, `redirect_uris` array present, `client_name` present
  4. Cache with TTL respecting HTTP cache headers (`Cache-Control: max-age`), default 24h ceiling
  5. Synthesize an ephemeral `Doorkeeper::Application` populated from the document (or pass-through in memory; spike outcome decides)
- On consent screen: clearly display the redirect URI hostname (CIMD §6 security MUST); show "this client is identified by a public document at: <URL>" so the user knows it's not a pre-registered client

Tests: SSRF block on `localhost`, `127.0.0.1`, `10.0.0.1`, IPv6 ULA; redirect-following blocked; oversized response rejected; `client_id` mismatch rejected; cache respects `max-age`; cache ceiling clamps malicious `max-age=31536000`.

**Risk:** CIMD is draft-00 of the IETF spec. Wire format may change. Keep the validator behind a feature flag (`mcp.cimd_enabled`) so we can turn it off without revoking issued tokens.

### Step 10 — RFC 7591 Dynamic Client Registration

Fallback for clients that don't speak CIMD yet (some still don't).

- `POST /oauth/register` accepts `client_name`, `redirect_uris`, `scope`, `token_endpoint_auth_method`, `application_type`
- Allowlist of params; reject anything outside the allowlist
- Returns `client_id` + (optional) `client_secret`; we issue only public clients (`token_endpoint_auth_method: "none"`) — confidential clients require pre-registration
- Rate-limited (per-IP, sustained) to block registration spam
- Tenant admin can disable DCR per-tenant via a tenant setting

Tests: rejected param produces 400; rate limit triggers 429; per-tenant disable flag returns 404; created client lands in `oauth_applications` table.

### Step 11 — "Connect Claude" button on agent settings

- New action on the agent settings page: "Connect this agent to an MCP client"
- Shows quick links: "Connect Claude Desktop" / "Connect Claude Code" / "Connect Cursor" / "Other (manual setup)"
- Each link kicks off the authorize flow with the right `client_id` and a `harmonic_agent=<handle>` hint
- "Other" reveals the canonical MCP URL + a button to mint a paste-token (the existing flow stays available)

Tests: button is rendered only when the human user is the agent's owner; clicking the link generates a valid `/oauth/authorize` URL with `client_id`, `code_challenge_method=S256`, `resource=<canonical MCP URI>`, `scope=read+write`, `state` (cryptographic), `redirect_uri` (pre-registered loopback for the chosen client).

### Step 12 — Update `/help/mcp` and the agent-creation flow

- `/help/mcp` adds a "Connecting a client" section that documents the Connect button
- The paste-token instructions stay (for clients that don't support OAuth yet, or for power users)
- Agent creation flow gains a "Connect a client now?" optional step that opens the Connect Claude UI inline

Tests: help page renders for both authenticated and anonymous visitors (existing pattern); agent-creation step is skippable.

## Cross-cutting concerns

**Where the OAuth endpoints mount.** Tenant subdomain root (`https://{subdomain}.harmonic.team/oauth/...`), NOT the auth subdomain. Each tenant runs its own AS so `aud` is tenant-bound. Both `.well-known` URLs likewise mount at tenant root.

**Consent screen authentication.** The human is authenticated via the existing session cookie (the tenant subdomain's session). If no session, redirect through `/login` first. The OAuth Connect flow does NOT introduce a new login UX.

**2FA on consent.** Optional Phase 2 enhancement: gate `/oauth/authorize` POST (the "Approve" button) behind a fresh 2FA check if the user has 2FA enabled. Defaults off in Phase 2 — toggle behind a tenant setting if the user wants it stricter. Existing 2FA infra (`OmniAuthIdentity#verify_otp`) plugs in directly.

**Paste-token coexistence.** Today's paste tokens keep working. `current_token` doesn't care whether the `ApiToken` was issued via OAuth or via the settings/tokens page; the row looks the same. The `audience` column is NULL on legacy paste tokens — `/mcp` exempts NULL-audience tokens from RFC 8707 check via an `internal: true` OR `paste_token: true` exemption; **the exact exemption shape is open** (see Open Questions).

**`mcp_only` interaction.** OAuth-issued tokens default to `mcp_only: true` because OAuth is the MCP-flow UX. Paste tokens stay with their current default (`true` for new external-agent tokens; `false` on legacy tokens). The "Settings → Tokens & Connected Apps" UI shows both groups with their respective state.

**Billing.** OAuth-issued tokens count toward the user's active-token cap and the per-agent billing the same as paste tokens. No new billing primitive.

**Audit log.** `McpToolCallLog.api_token_id` already FKs to `ApiToken`. The new `act` / `oauth_client_id` columns appear in audit-log queries via `ApiToken` join. The principal-review UI surfaces client_name on each call row.

**Rate limits.** Unchanged — per-token and per-principal. The "principal" key is `User#principal_id` which is `parent_id || id`; works identically for OAuth and paste tokens.

## Phase 1 follow-up that's a soft dependency

The hosted-mcp-server plan flagged connection-level audit (initialize/ping/tools-list) as deferred from Phase 1. Phase 2's "Connected Apps" UI would benefit from at least last-`initialize`-at on each token row so users can see "last connected via Claude Desktop, 12s ago." Worth landing as a Phase 1 follow-up either before or alongside Step 11.

## Test strategy

- **Doorkeeper integration tests** — full grant flows: pre-registered client + PKCE happy path; PKCE missing → reject; refresh rotation; revocation
- **`.well-known` schema tests** — assert documents match the RFC JSON schemas (validators exist on rubygems)
- **`/mcp` audience tests** — issued token with correct audience → 200; mismatched audience → 401; missing audience on a non-paste token → 401
- **CIMD security tests** — SSRF blocks (every reserved IP range), oversized doc, mismatched client_id, redirect-following blocked
- **Consent UI tests** — agent picker scoped to caller; cross-tenant agent selection blocked; revoke kills both tokens; "Connect Claude" button only renders for owner
- **Token-claim tests** — every OAuth-issued `ApiToken` has `sub`/`act`/`aud`/`client_id` populated; capability check uses `sub` not `act`; `McpToolCallLog` is populated correctly per-call
- **Audit log tests** — `last_used_at` on the token, audit row carries `oauth_client_id`

## Risks / open questions

- **Spike result (Step 1) may force the parallel-token-system fallback.** If Doorkeeper's storage model resists `ApiToken` integration, we end up with two `current_token` paths and have to migrate one direction or the other. Spike is the first thing to do.
- **CIMD wire format is draft-00.** The IETF spec may change before stabilizing. Isolate the validator behind a feature flag and a single file so swapping is a small PR. Reading the GA spec when it ships is mandatory.
- **Legacy paste-token grandfathering.** Open: do we leave them NULL-audience and exempt by token type, or backfill them to a synthetic `audience` matching the tenant's MCP URI? Backfill is cleaner long-term (one validation path); but requires a migration that may collide with multi-tenancy if any token has a wrong `tenant_id`. **Pick during Step 5.**
- **2FA on consent.** Whether to require fresh 2FA on the consent screen affects the perceived security ceiling of the flow. Default off; tenant-toggleable. Reconsider if a Connect-flow phishing pattern emerges.
- **Doorkeeper's `Doorkeeper::Application` columns vs CIMD's ephemeral clients.** Either we synthesize a row on every CIMD validation (write-heavy, cleanup overhead) or we override `Doorkeeper::OAuth::Client.find` to return a CIMD-backed in-memory object (cleaner, more code). Spike confirms which.
- **JWT vs opaque tokens.** Plan assumes opaque (`ApiToken.token_hash`). MCP spec doesn't mandate JWT. JWTs would require `jwks_uri` and `kid` rotation; opaque tokens need only validation against our DB. Sticking with opaque unless we find a downstream service that needs to validate without a DB round-trip.

## Verify before kickoff

- Confirm Phase 1 audit-log connection-level coverage (initialize/ping/tools-list) state before designing Connected Apps "last seen" indicator.
- Confirm Caddy / load-balancer config: `.well-known/oauth-*` paths need to NOT be intercepted or rewritten before reaching Rails (some Caddy configs intercept `.well-known/` for ACME).
- Confirm `Doorkeeper::Application#redirect_uri` supports OAuth 2.1 loopback redirect (varying port for `127.0.0.1`/`localhost`) without custom code.

## Out of scope

- **Federated AS** (MCP server pointing at an external authz server) — not in Phase 2
- **Step-up authorization on insufficient-scope** (`403 → re-auth with more scopes`) — defer until a real use case appears
- **Per-collective token scopes** (`collective:acme:write`) — capabilities are the per-collective gate today; OAuth scopes stay at `read`/`write`
- **OIDC `userinfo` endpoint** — not an MCP requirement; skip unless a partner asks
- **OAuth as a *client* refactor** — Phase 2 builds an AS for MCP only. Existing OmniAuth-driven Google/GitHub login is unchanged.
- **Removing the paste-token UX** — stays available alongside the Connect button. Retirement is a post-Phase-2 follow-up once OAuth adoption is high.

## Rollout sequence

1. Step 1 spike (decides Step 6 shape)
2. Steps 2–6 in one or two PRs (Doorkeeper install + metadata + audience binding) — gated behind a tenant feature flag (`mcp.oauth_enabled`)
3. Step 7 (consent screen) — internal tenant testing first
4. Step 8 (pre-registered clients) — get Claude Desktop / Code / Cursor working end-to-end
5. Step 9 (CIMD) — feature-flagged, dogfood with one CIMD-publishing client
6. Step 10 (DCR) — fallback path, ship together with CIMD
7. Step 11 (Connect button) — flip on for one internal tenant, then rollout
8. Step 12 (docs + flow) — final polish

Each step keeps the paste-token path working. No flag day. The only "removal" event is when we eventually retire the paste-token form from the default UX — that's a post-Phase-2 decision.
