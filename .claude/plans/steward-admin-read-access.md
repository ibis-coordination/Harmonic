# Steward read access to system-admin pages

**Status: design settled 2026-08-22 (steward-identity decision made); implementing.**

Read-only agent access to the existing markdown system-admin pages (Sidekiq
queues/retries/scheduled/dead, dashboard, task runs), consumed through
`harmonic-admin prod page <path>`. First concrete step of moving admin
capability into Harmonic itself: Harmonic owns the pages and auth; the CLI
is a thin authenticated pager.

## Settled decisions

- **Steward identity, not Dan's token.** A dedicated external `ai_agent`
  user (principaled by Dan, on the primary tenant) holds the credential.
  Attribution is honest from day one; the same identity later graduates to
  MCP on a sprite. Agents acting under a human's credential is the pattern
  Harmonic exists to avoid.
- **Pager, not parser.** The CLI prints page markdown verbatim; it never
  extracts or re-renders. Structure belongs Rails-side. Curated aliases
  (if ever) map to paths, never parse content.
- **Token-flag enforcement on system-admin.** `ensure_sys_admin` gains the
  documented redundant-check pattern (user role AND token flag, as
  `Api::AppAdminController` already does): token-authenticated requests
  require `@current_token.sys_admin?`. Ordinary tokens of sys_admin users
  no longer reach admin pages — closes an existing gap and contains the
  steward credential to exactly this surface.
- **CLI stays read-only permanently.** Mutations (e.g. dead-job retry) are
  not deferred — they're out of scope forever. The eventual mutation path
  is Harmonic's action system via MCP under the steward's identity, with
  governance gates.
- Read scope + GET is double containment; the token cannot mutate even
  where a write surface exists.

## Changes

1. **Rails**: `SystemAdminController#ensure_sys_admin` — when
   `api_token_present?`, also require `@current_token.sys_admin?`.
   Tests: flagged token + sys_admin user → 200 on md pages; unflagged
   token + sys_admin user → 403; flagged token + non-sys_admin user → 403;
   read-scope token POSTing retry → rejected.
2. **CLI**: `harmonic-admin prod page <path>` — GET `{prod}{path}` with
   `Accept: text/markdown` + bearer `HARMONIC_STEWARD_TOKEN`; print body
   verbatim. Degrades to "no access" when the key is missing. Doctor row +
   help text (acts on prod over HTTPS; read-only).

## Provisioning (Dan, prod console — after code ships)

```ruby
steward = ... # create external AI agent principaled by Dan, primary tenant, e.g. handle "steward"
steward.update!(sys_admin: true)
token = steward.api_tokens.new(
  name: "harmonic-admin steward read",
  token_type: "rest",
  scopes: ApiToken.read_scopes,
  sys_admin: true,
  expires_at: 1.year.from_now,
)
token.save!
token.plaintext_token  # → ~/.config/harmonic-admin/env as HARMONIC_STEWARD_TOKEN
```

Facts: token admin flags are not settable via the tokens UI (console-only,
by design); tokens are tenant-scoped so the steward + token must be on the
primary tenant; reverification already exempts token auth.

Preconditions verified in dev e2e:
- the primary tenant must have API enabled (`tenant.enable_api!`);
- the steward's **principal must be fully activated** on the primary tenant
  (token auth gates agent tokens on the parent human's activation;
  sys_admin humans count as activated, so Dan qualifies).

## Later

- Steward as resident sprite agent using MCP `fetch_page` (same identity).
- Narrower Rails-side scope only if a trigger appears beyond the token
  flag (e.g. wanting per-page grants).
- `prod status` unchanged; dead-count already surfaces via /metrics.
