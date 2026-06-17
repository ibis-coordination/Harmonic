# Hosted MCP Server

## Goal

Collapse the AI-agent setup flow from "create agent → copy token → clone repo → npm install → npm build → edit JSON config with absolute path → restart client → hope" down to "create agent → click Connect Claude" (or, in an intermediate state, "paste server URL + token").

The path to that collapse is **hosting the MCP server inside Harmonic** instead of shipping it as a local npm package. The legacy local server (now deleted) was a thin passthrough that translated MCP-over-stdio into HTTP-with-Bearer-auth. Every byte of real behavior — markdown rendering, action dispatch, search, help — lives in Rails. Moving the protocol envelope into Rails removes the local install entirely and keeps tools always in sync with the app.

## Background: Spec we are targeting

- **Protocol version**: `2025-11-25` (current stable). A `2026-07-28` release candidate is locked but not GA. Pin to `2025-11-25` and revisit when the RC ships.
- **Transport**: Streamable HTTP — single `/mcp` endpoint, POST for client → server, optional GET for SSE streams, `Content-Type` negotiation between `application/json` and `text/event-stream`.
- **Auth (RFC-anchored)**:
  - OAuth 2.1 (PKCE + S256, mandatory)
  - Protected Resource Metadata, RFC 9728 (server MUST implement)
  - Authorization Server Metadata, RFC 8414 (authz server MUST implement)
  - Resource Indicators, RFC 8707 (client MUST send `resource` param; server MUST validate audience)
  - Client ID Metadata Documents (new preferred client-registration; Dynamic Client Registration kept as fallback)
- **Security**: MUST validate `Origin` header on every request (DNS rebinding mitigation). MUST reject tokens not issued for this server's audience.

## Architecture

Harmonic plays two roles in the spec:

1. **Resource server** — the `/mcp` endpoint itself. This is the small, well-scoped piece.
2. **Authorization server** — issues tokens that name `/mcp` as audience. This is the larger piece.

The spec explicitly allows these to be the same process or separate. We co-locate them in Rails. The current `AUTH_MODE=oauth` setting makes Harmonic an OAuth *client* of upstream providers (Google etc.) — that is unrelated to becoming an OAuth *server* and is preserved. The new authz-server capability sits alongside it.

For Phase 1 we ship the resource server only, using existing [API tokens](../../app/models/api_token.rb) as bearer credentials. For Phase 2 we add the authz server and switch the default UX to OAuth.

**Coexistence**: legacy Bearer tokens and OAuth tokens both work against `/mcp` permanently. Phase 2 doesn't deprecate Bearer — it adds OAuth as the new default UX. The local stdio package continues to work against either token type. Removing Bearer would only be considered far in the future, behind a separate deprecation plan.

## Phase 1: Streamable HTTP MCP endpoint with Bearer auth

Ship a working hosted MCP server that accepts existing API tokens. The user flow shrinks from "install + config + token + path" to "paste URL + token into client's Add-MCP-Server UI." No npm, no Node, no path resolution, no rebuilds when we ship MCP updates. This is shippable on its own. The remaining friction after Phase 1 is the token paste itself — Phase 2 (OAuth) eliminates that.

### Scope

- New Rails route `POST /mcp` (and `GET /mcp` for SSE-from-server, optional in v1)
- `Mcp::EndpointController` handles JSON-RPC envelope (`initialize`, `initialized`, `tools/list`, `tools/call`, `resources/list`, `resources/read`, `ping`)
- Four tools — `fetch_page`, `execute_action`, `search`, `get_help` — implemented in Ruby, invoking a **shared service layer** (existing `MarkdownUiService` and equivalent for action dispatch; extract an action-dispatcher service if one doesn't exist yet) that the existing HTTP controllers already use. Both the existing `Accept: text/markdown` HTTP controllers and `Mcp::EndpointController` are thin shells around the same services. Auth (Bearer + tenancy scoping) happens at the controller layer in both. Capability checks live inside the service / action handlers and apply uniformly. **Do not** re-implement the markdown rendering or action dispatch logic inside the MCP controller.
- `harmonic://context` resource serves the orientation document via `resources/list` + `resources/read`
- Bearer auth: reuse `ApiToken` lookup, return `401 Unauthorized` with `WWW-Authenticate: Bearer resource_metadata="..."` (preps for Phase 2 discovery)
- `Origin` header policy: **if present and not in the tenant host allowlist, 403; missing Origin is allowed.** Desktop MCP clients (Claude Desktop, Claude Code, Cursor) don't send Origin — the spec's check is DNS-rebinding protection that only meaningfully applies to browser-based callers. Reject bad Origin, allow absent Origin.
- `MCP-Protocol-Version` header parsing + 400 on unsupported
- **No `MCP-Session-Id` in v1.** Every request is independently auth'd by Bearer; we don't issue session IDs and don't require them. (Spec is clear: if the server doesn't issue, the client doesn't send.) Defer sessions to a later phase if streaming or stateful flows need them.
- Per-tenant routing via existing subdomain middleware — `https://acme.harmonic.team/mcp` already routes correctly. No unified `mcp.harmonic.team` endpoint in v1 (revisit if multi-tenant users ask).
- Tenant + collective API-access checks unchanged; same 403 path as REST API
- **Rate limits** (shipped): four layered scopes —
  - Per-token burst: 10 req/sec
  - Per-token sustained: 60 req/min
  - Per-principal sustained: 600 req/min — caps cumulative throughput across all of one human's agents (the principal is `user.parent_id || user.id`). Keeps one paying principal from starving the tenant for everyone else.
  - Per-tenant aggregate: 6,000 req/min default; tunable per tenant via `Tenant#mcp_aggregate_rate_limit_per_minute` (a `settings` jsonb key) for public tenants that outgrow the default. **Operator-controlled** — tenant admins cannot raise their own ceiling (the tenant_admin settings form uses an explicit allowlist that excludes this key). Set via Rails console or future app-admin tooling.

  Plus a 1 MiB response body cap. Counters live in Redis via the existing `RateLimits` concern; exceeding any one returns `429` with `Retry-After` and the breached scope name in the response message. Every rate-limit event is logged to `SecurityAuditLog` (`log/security_audit.log`) with `event=mcp_rate_limited` + scope, token, tenant, user, principal, ip, request_id — operators can grep / aggregate from there to detect abusive agents, principals, or tenants. No metered overage billing in v1 — measure first, decide later.
- **Audit logging**: every MCP tool call writes an `McpToolCallLog` entry tagged with the agent identity, tool name, redacted args, status, duration, and `request_id`. Foundation for the principal accountability surface that lands in Phase 2.
- **`mcp_only` token mode** (see subsection below): a per-token boolean. When set, the token can only be used through `/mcp` — any direct REST or markdown call (read or write) returns 403. Default `true` for new agent tokens; existing tokens migrate as `false` so nothing breaks. Converts the audit guarantee from "every write is logged" to "every action is logged" for tokens that opt in.

### TDD test list (`test/controllers/mcp/endpoint_controller_test.rb`)

- `POST /mcp` without Authorization → 401 + WWW-Authenticate header with `resource_metadata` URL
- `POST /mcp` with invalid token → 401
- `POST /mcp` with token from a different tenant → 401 (tenant scoping)
- `POST /mcp` with bad `Origin` → 403
- `POST /mcp` with missing `Origin` (typical desktop client) → allowed
- `POST /mcp` with unsupported `MCP-Protocol-Version` → 400
- `initialize` request → returns server capabilities (`tools` and `resources` only — no `prompts`, `logging`, or `sampling`) and protocol version; response does **not** include `MCP-Session-Id` header
- `tools/list` → returns the four tool descriptors with current input schemas
- `tools/call` for `fetch_page` with valid path → returns markdown body
- `tools/call` for `fetch_page` with 404 path → returns MCP-shaped error with content
- `tools/call` for `execute_action` → POSTs internally to action endpoint, returns markdown result
- `tools/call` for unknown tool → MCP method-not-found JSON-RPC error
- `resources/list` → includes `harmonic://context`
- `resources/read` for `harmonic://context` → returns context markdown
- Notifications return 202 with no body
- `POST /mcp` with a JSON-array body (JSON-RPC batch) → 400. Streamable HTTP spec requires single-message POST bodies.
- Capability check failures (e.g., agent lacks `create_note`) surface as tool errors, not auth errors

### Out of scope for Phase 1

- SSE streaming responses (every Harmonic action is short-lived; return `application/json` always)
- Server-initiated requests (sampling, elicitation, roots) — we don't need them yet
- Session resumability + `Last-Event-ID`
- Token audience claims — Phase 2 with OAuth
- OAuth discovery beyond pointing at a placeholder URL

### Documentation deliverables (Phase 1)

- Delete the legacy `mcp-server/` directory (now removed; the hosted endpoint is the only path)
- Update [app/views/help/api.md.erb](../../app/views/help/api.md.erb) with a "Connect via MCP" section
- New help page `app/views/help/connect-agent.md.erb` covering the end-to-end flow against the hosted endpoint

### `mcp_only` token mode

**Goal:** make "every action taken with this token is traceable to a specific MCP call" a structural property of opt-in tokens, not an honor-system invariant. The audit log on its own can be bypassed by an agent that authenticates the same Bearer token against direct REST or markdown endpoints — no `McpToolCallLog` row gets written. The `mcp_only` flag closes that back door for tokens that have it set: every action by that token must go through `/mcp`, which means every action lands in the audit log.

The toggle is per-token rather than system-wide. Most users get the strong guarantee by default; advanced users with a legitimate need for direct REST or markdown access (legacy scripts, deterministic automation, etc.) can opt out at token creation or later in the agent settings UI.

This subsection lands **after** the audit-logging work in [app/models/mcp_tool_call_log.rb](../../app/models/mcp_tool_call_log.rb) and **before** rate limits, because the audit log is the *enforcement substrate* for this restriction — without it the rule has no meaning, with it the rule completes the guarantee.

#### Rule

If `token.user.ai_agent? && token.mcp_only?`, the token may only be used when the request originates from MCP's inner dispatch through `MarkdownUiService`. Any direct external HTTPS request with that token — read or write, any HTTP method — returns `403` with an agent-readable error pointing at `/help/mcp`.

Human tokens are unaffected (the check skips on user_type). Tokens with `mcp_only: false` are unaffected (the existing behavior persists).

The rule applies the same way regardless of token shape, but defaults differ: external agent tokens default to `mcp_only: true`, internal agent tokens default to `mcp_only: false`. The constraining caller is `AgentRunnerDispatchService` — it hands the token to a separate Node.js process (the agent runner) that calls Rails directly over HTTPS, without going through `MarkdownUiService`. The runner can't set the `internal_dispatch` env flag from outside the Rails process, so an `mcp_only: true` internal token would 403 every agent-runner action. (Deterministic-rule automations via `AutomationInternalActionService` *do* dispatch through `MarkdownUiService` and would satisfy the flag, but `ApiToken.create_internal_token` can't distinguish callers at the point of issuance, so the safe minimum is `false` for all.) Phase 5 (agent-runner migration to `/mcp`) lets us flip the default.

#### Detection mechanism

The "did this come through MCP's dispatch?" signal needs to be tamper-proof — clients must not be able to forge it by setting an HTTP header.

`MarkdownUiService`, when dispatching an inner request through `ActionDispatch::Integration::Session`, passes `env: { "harmonic.internal_dispatch" => true }`. That env key is settable only by in-process code; external HTTP headers always arrive as `HTTP_*`-prefixed, so they cannot conjure the bare key.

The check in `api_authorize!` reads `request.env["harmonic.internal_dispatch"]`. If the token is an `mcp_only` agent token and the flag is absent → 403.

Flag named "internal dispatch" rather than "via MCP" because the agent-runner's internal-token path *also* dispatches through `MarkdownUiService` today, and we want internal agents to keep working under `mcp_only: true`. Once Phase 5 routes the runner through `/mcp` directly, the flag is still set there too. Either way the rule holds.

#### Defaults

- **New external agent tokens** (created via the agent settings form / API): `mcp_only: true`
- **New internal agent tokens** (issued by `AgentRunnerDispatchService` / `MarkdownUiService#with_internal_token`): `mcp_only: false` for now, because the agent runner makes direct HTTPS calls that can't set the env flag. Phase 5 flips this to true alongside the runner's migration to `/mcp`.
- **Migration backfill for existing tokens at column-add time**: `mcp_only: false` — no breaking change for anything in production today
- **Human tokens**: column populated as `false`; the check ignores it anyway

#### Implementation

1. **Migration** — add `mcp_only: boolean, null: false, default: false` to `api_tokens`. Existing rows default false. The new default value is set in application code at token creation, not in the DB default, so the column default stays migration-safe.
2. **`MarkdownUiService`** — set `env["harmonic.internal_dispatch"] = true` on every internal dispatch.
3. **`ApplicationController#api_authorize!`** — after token resolution, if the token user is an AI agent, the token has `mcp_only: true`, and the env flag is absent, render a 403 JSON envelope:
   ```
   { "error": "This token is set to MCP-only mode. Use it through the /mcp endpoint, or disable MCP-only access in the agent settings. See /help/mcp." }
   ```
4. **Token creation form** — add the toggle (default checked for new agent tokens). The flag is set at token creation only; API tokens are immutable, so changing modes means deleting the token and creating a new one.
5. **`/help/mcp` and `/help/agents`** — state the rule, explain the toggle and the delete-and-recreate path, link the error message back.

#### Coverage audit (before committing)

`api_authorize!` is the centralized API gate, but a quick grep verifies nothing reads or writes outside it:

- Attachment uploads — does `attachments_controller` go through `api_authorize!`?
- `Internal::*` controllers reachable by external Bearer — any?
- OAuth callback endpoints — POSTs but not Bearer-authed; irrelevant.
- Action endpoints (`/collectives/.../n/.../actions/...`) — covered via the standard filter chain. Includes `confirm_read`, intentionally covered.
- `Accept: text/markdown` direct reads — these go through normal controllers gated by `api_authorize!`. Covered.

Any gap found gets handled case-by-case before this restriction commits.

#### Tests

- Agent token with `mcp_only: true` + direct `POST /collectives/.../actions/create_note` → 403, no `Note` created
- Agent token with `mcp_only: true` + direct `GET /whoami` → 403
- Agent token with `mcp_only: true` + read via `/mcp` (`fetch_page("/whoami")`) → allowed
- Agent token with `mcp_only: true` + write via `/mcp` (`execute_action`) → allowed
- Agent token with `mcp_only: false` + direct `GET` or `POST` → allowed (no restriction)
- Internal agent token (default `true`) + write via agent runner → allowed (env flag set by `MarkdownUiService`)
- Human token + direct anything → allowed (check doesn't fire)
- Token-creation form defaults `mcp_only: true`
- Existing tokens at migration backfill: `mcp_only: false`
- Error response body is JSON-shaped and the message names `/help/mcp`

#### Tradeoffs

- **No breaking change for anything in production.** Existing tokens default false at backfill. New tokens default true. Users discover the restriction at token-creation time when they read the toggle description.
- **The audit guarantee is per-token, not system-wide.** Honest framing: "every action by an `mcp_only` token is logged." The principal-review UI can show which tokens have the flag on so the principal knows the completeness of the audit trail.
- **Log volume goes up for `mcp_only` tokens.** Reads are voluminous compared to writes. Retention policy needs a decision before this ships at scale. For Phase 1 the volume is bounded by Phase 1 traffic, so it's not urgent — but flag it as a Phase 2-era concern.

## Phase 2: OAuth 2.1 authorization server

Replace "paste token" with "Connect Claude." User clicks a button in their client, browser opens to a Harmonic consent screen, user approves, client gets a token transparently. The token-handling step disappears entirely from the setup flow.

### Scope

- Adopt **Doorkeeper** (or equivalent) as the OAuth 2.1 authz server backend. **Open risk**: Doorkeeper's OAuth 2.0 support is solid, but Client ID Metadata Documents (new in this spec rev) and RFC 8707 audience-bound Resource Indicators are not core features. Before Phase 2 kickoff, do a gap analysis: which spec requirements does Doorkeeper cover, which need extension PRs / monkey-patches, and is there a newer alternative worth adopting instead.
- Implement RFC 9728 Protected Resource Metadata at `.well-known/oauth-protected-resource` (and sub-path variant)
- Implement RFC 8414 Authorization Server Metadata at `.well-known/oauth-authorization-server`
- PKCE with S256 (mandatory); reject non-PKCE flows
- Support **Client ID Metadata Documents** — fetch and validate URL-formatted `client_id`s; SSRF guards required
- Pre-register Claude Desktop, Claude Code, Cursor as known clients for zero-config first install. "Pre-register" here means accepting their wildcard redirect URI pattern (`http://localhost:*/callback` — these clients use dynamic localhost ports per MCP convention), not literal URIs.
- Dynamic Client Registration (RFC 7591) as fallback for clients that don't yet support CIMD
- Bind tokens to `resource` audience (RFC 8707); reject tokens whose audience doesn't match `/mcp` on this tenant
- Refresh tokens with rotation (mandatory for public clients per spec)
- Consent screen: scopes shown plainly, parent-agent relationship visible, "Connected Apps" management UI on the user's settings page with per-client revoke
- Replace 401's `WWW-Authenticate` with real `resource_metadata` URL

### Token-to-agent binding

Each token is bound to exactly one agent identity at issuance. This preserves today's "1 token = 1 acting user" model, just delivered through OAuth.

- **Token claims**:
  - `sub` = the agent identity (what `/whoami` returns; what capability checks scope to)
  - `act` = parent human user (accountability; surfaced in audit chain and "Connected Apps" UI). Loose convention from [RFC 8693 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693).
  - `aud` = the MCP endpoint URL for this tenant (RFC 8707)
  - `scope` = permissions (read / write / etc.); independent of identity
  - `client_id` = which OAuth client (Claude Desktop, Cursor, etc.)
- **Consent screen** authenticates the human, then presents an **agent picker** listing all agents they manage, plus a "+ Create a new agent" inline option. The picked agent becomes the token's `sub`.
- **One Connect flow = one token = one agent.** Connecting the same client (e.g., Claude Desktop) to a second agent produces a separate token and a separate MCP server entry in the client's config. Client app is reusable; tokens are not.
- **Immutable binding.** Refresh tokens inherit the same `sub`; you cannot mint a Research Bot access token from a Meeting Helper refresh token. To switch which agent a client acts as, revoke and re-Connect.
- **Identity hint**: support an optional `harmonic_agent=<handle>` query param on the authorize endpoint that pre-selects an agent on the consent screen (still requires user confirmation). Lets clients deep-link from "Connect as Meeting Helper" buttons elsewhere in Harmonic.

### Resolved decisions

- **Token lifetime**: 1 hour access / 60 day refresh, with rotation. Matches GitHub / Google norms; refresh rotation doubles as a leak detector. Legacy Phase 1 Bearer tokens keep today's up-to-1-year cap.
- **Scope model**: `read` and `write` only. Fine-grained permission lives at the agent-capability layer (already in [app/views/ai_agents/new.html.erb](../../app/views/ai_agents/new.html.erb), checked via `CapabilityCheck`). Effective permission on any request = intersection of token scope and agent capability. Per-collective scopes (`collective:acme:write`) deferred until requested — that's the dimension capabilities don't cover.

### Existing infrastructure to reuse

- [app/models/api_token.rb](../../app/models/api_token.rb) for the token storage model — extend rather than replace
- Existing per-user `/u/:handle/settings/tokens` page becomes "Tokens & Connected Apps" with two sections
- Tenant scoping mechanics carry over unchanged

### Out of scope for Phase 2

- Step-up authorization flows (insufficient_scope → re-auth) — defer to Phase 5+
- Federated OAuth (e.g., MCP server pointing at an external authz server)

## Phase 3: Setup UX improvements

Parallel to Phases 1–2. None of these require the hosted endpoint; they smooth the agent-creation half of the flow.

- **Preset identity templates** in [app/views/ai_agents/new.html.erb](../../app/views/ai_agents/new.html.erb): "Research assistant / meeting summarizer / decision companion / inbox triage" — clicking a tile populates name + identity prompt + suggested capability set + recommended model
- **Capability descriptions** next to each group in the form (one-line plain English per group)
- **Prompt to enable API access** during agent creation if tenant or collective API access is currently disabled and the user is admin — single-click enable with a clear explanation of what gets exposed. Never silent; the tenant admin may have intentionally disabled it. If the user is not admin, surface a clear "ask your admin" message with a copy-paste link.
- **Connection status indicator** on the agent's profile: "Last seen 12s ago via Claude Desktop" — reads from a per-token `last_used_at` already tracked by `ApiToken`
- **`/connect` short URL** that redirects to whichever step the user is on (billing → create agent → connect client → done)

These are small, high-leverage changes the user can ship independently of the MCP work.

## Phase 5: Agent-runner consolidation

Migrate the internal agent-runner ([agent-runner/](../../agent-runner/)) to use `/mcp` as its tool transport, replacing its bespoke HTTP wrapper. This unifies internal and external agents on a single tool surface — same protocol, same semantics, same code path.

Ordering: after Phase 1 ships and is stable in production. Not blocked by Phase 2 (OAuth) — internal agents can keep using their existing ephemeral API tokens as Bearer credentials against `/mcp`.

### Scope

- Replace the agent-runner's internal "navigate" and "execute_action" HTTP calls with calls to a standard MCP client SDK pointed at `https://{tenant}.harmonic.team/mcp`
- Drop the agent-runner's custom Bearer + Host-header wrapper; the MCP client SDK handles transport
- Agent-runner's existing ephemeral encrypted token issuance ([docs/AGENT_RUNNER.md](../../docs/AGENT_RUNNER.md)) is unchanged — those tokens are valid Bearer credentials at `/mcp`
- Internal-agent tool schemas (passed to the LLM) get generated from MCP's `tools/list` response, not hardcoded in the runner
- New tools added to `/mcp` automatically become available to internal agents — no runner change required

### Benefits

- One tool surface to maintain. New capabilities ship in one place.
- Identical semantics: "what the internal agent can do" structurally equals "what the external agent can do."
- Every internal agent run in production doubles as integration coverage of `/mcp`.
- Agent-runner code shrinks — bespoke HTTP layer replaced with an SDK call.

### Risks / things to watch

- **Latency**: today's agent-runner is in the same datacenter as Rails and may be using internal networking. MCP-over-HTTPS adds TLS handshake overhead per request. Mitigate with connection keepalive (standard for any HTTP client).
- **Tool semantic drift**: if a tool's behavior differs subtly under MCP vs the runner's old wrapper, internal agents may regress. Pin the parity check to the test suite — run the existing internal-agent test scenarios against the new MCP-based runner before flipping the default.
- **Streaming / progress**: if any internal-agent tool benefits from streamed progress today, that capability needs to translate to MCP's response model. Most current tools are short-lived enough not to matter.

### Logging-system consolidation (agent-runner side only)

When the agent-runner moves to `/mcp`, every internal-agent action becomes an MCP tool call. Without consolidation, we'd double-record: an `AiAgentTaskRunResource` row *and* an `McpToolCallLog` row for the same action.

This affects only the **agent-runner / AiAgentTaskRun** side of the existing logging systems. `AutomationRuleRun` + `AutomationRuleRunResource` and `RepresentationSession` + `RepresentationSessionEvent` are independent flows that don't go through `/mcp` and stay exactly as they are.

**Endgame shape for the agent-runner side** — three grains:

```
AiAgentTaskRun (parent context for internal agent runs)
  lifecycle, token usage, cost, started_at/completed_at, error
        │
        ▼
McpToolCallLog (per call — always present once internal agents route through /mcp)
  user_id, tool_name, args, status, duration_ms, request_id
  ai_agent_task_run_id?  (FK — set for internal-agent calls, nil for external clients)
        │
        ▼
McpToolCallResource (per resource touched — mirrors the existing pattern)
  mcp_tool_call_log_id, resource (polymorphic), action_type,
  resource_collective_id, display_path
```

`AiAgentTaskRun` keeps its lifecycle role (token budget, completion status). What changes: `AiAgentTaskRunResource` is replaced by `McpToolCallResource`, which hangs off the per-call grain instead of the per-task-run grain.

A task run that issues 12 tool calls produces 12 `McpToolCallLog` rows sharing the same `ai_agent_task_run_id`; resources hang off the calls. "What did this task run create?" is `task_run → calls → resources`. "What did this specific call create?" is one join.

**Migration path:**

1. Add nullable `ai_agent_task_run_id` to `McpToolCallLog`. Additive migration.
2. Migrate the agent-runner to `/mcp` (the rest of Phase 5). Threadlocal context surfaces the active `AiAgentTaskRun` to the MCP controller, which stamps the FK.
3. Add `McpToolCallResource`. Have `track_task_run_resource` in `api_helper` write to *both* `AiAgentTaskRunResource` *and* `McpToolCallResource` during the transition.
4. Once dual-write is stable, deprecate `AiAgentTaskRunResource`. Backfill historical attribution via the FK chain. Remove the table.

**What Phase 1 must avoid** to keep this path open: don't add shapes to `McpToolCallLog` that assume external-MCP-only context (e.g., a non-nullable `external_client_origin`, coupling to the Bearer-auth code path, or anything that would break for internal-token callers). The current schema is already orthogonal — adding `ai_agent_task_run_id` later is purely additive.

**What Phase 1 deliberately skipped:** the `McpToolCallResource` table. Designing it now without the Phase 5 constraints in view would mean guessing at the resource-tracking integration. Existing `track_task_run_resource` works for internal agents today; we extend the model to MCP-driven actions when Phase 5 actually starts.

### Out of scope for Phase 5

- Changing how the agent-runner picks up tasks from Redis
- Changing the agent-runner's LLM-loop logic
- Changing how internal tokens are issued or rotated

## Spec compliance checklist

Use this when reviewing Phase 1 / Phase 2 PRs.

**Phase 1 (Streamable HTTP, Bearer):**

- [ ] Single endpoint accepts POST
- [ ] `Accept` header validation (`application/json` and/or `text/event-stream`)
- [ ] `Origin` header validated
- [ ] `MCP-Protocol-Version` header parsed; 400 on unsupported
- [ ] 401 includes `WWW-Authenticate: Bearer resource_metadata="..."`
- [ ] JSON-RPC error shapes correct (method not found, invalid params, internal error)
- [ ] Tool errors returned as `isError: true` content, not JSON-RPC errors

**Phase 2 (OAuth 2.1):**

- [ ] `.well-known/oauth-protected-resource` returns valid RFC 9728 document
- [ ] `.well-known/oauth-authorization-server` returns valid RFC 8414 document
- [ ] PKCE S256 enforced; non-PKCE rejected
- [ ] `code_challenge_methods_supported: ["S256"]` advertised
- [ ] `resource` parameter required and used to bind audience
- [ ] Audience validation on every `/mcp` request
- [ ] Refresh token rotation for public clients
- [ ] Client ID Metadata Documents supported with SSRF guards on fetch
- [ ] `client_id_metadata_document_supported: true` advertised
- [ ] Token `sub` = agent identity; `act` = parent human; both checked on every MCP request
- [ ] Refresh tokens preserve `sub` (cannot mint cross-agent tokens)

## Resolved cross-cutting decisions

- **Routing**: per-tenant subdomains only (`https://{subdomain}.harmonic.team/mcp`). No unified endpoint in v1.
- **Rate limits**: 60/min per token, 10/sec burst, 1MB response cap, per-tenant aggregate cap. No metered overage billing v1.
- **Client compatibility**: test Claude Desktop + Claude Code in Phase 1. Other clients (Cursor, etc.) documented as expected-to-work with config blocks but not gating launch. Support means "we test on every release."

## Open questions

- **Refresh-token UX edge cases**: what happens if a user revokes an agent while a refresh token is still valid? Presumably the next refresh fails — confirm the UI surfaces this clearly to the user in the connected client.
- **2026-07-28 spec RC**: pin to `2025-11-25` for build; revisit spec compliance when the RC ships to GA.

## Verify during Phase 1 kickoff

Quick code checks before relying on these assumptions:

- **Where capability checks live**: plan assumes capability enforcement (`CapabilityCheck`) is inside service / action-handler code, not as controller filters. If they're filters, the MCP controller has to invoke them explicitly. Quick grep before extracting the shared service layer.
- **`ApiToken.last_used_at` already tracked**: Phase 3 connection-status indicator depends on this. If absent, add it as Phase 3 scope.
- **`MCP-Protocol-Version` missing-header policy**: pick during Phase 1 implementation — default to `2025-11-25` (rejecting old clients) or follow the spec's backwards-compat hint (`2025-03-26`). Either is defensible; commit and test.

## Out of scope

- ChatGPT custom GPTs — they use OpenAPI / actions, not MCP. Separate adapter, separate plan.
- The dual-interface markdown protocol — `Accept: text/markdown` keeps working for users who prefer raw HTTP (subject to the `mcp_only` rule for tokens that have it set).

## Rollout sequence

1. Phase 3 polish (presets, capability descriptions, status indicator) — shippable now, no spec dependency
2. Phase 1 (Bearer hosted MCP, audit log, `mcp_only` mode, rate limits) — biggest single user-facing win after polish
3. Phase 5 (agent-runner consolidation + AiAgentTaskRun logging unification) — internal-agent dogfooding of `/mcp` before OAuth complexity lands; can run in parallel with Phase 2 design work
4. Phase 2 (OAuth 2.1) — large project, ship behind a feature flag, dogfood internally first
5. After Phase 2: add a "Connect Claude" button to the agent-create flow (and `/connect`); retire the token-paste path from default UX, keeping it available for advanced users
