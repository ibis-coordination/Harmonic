# Plan: Make the v1 REST API read-only

## Context

The v1 REST API at `/api/v1/*` has been neglected and shows signs of drift — the InfoController route list was hardcoded and missing most endpoints (fixed in the help-topics branch), and the controllers haven't kept pace with the design and security work that's gone into the markdown UI's action routes.

Every writeable resource currently has two parallel write paths:

| Path | Mechanism |
|------|-----------|
| `POST /api/v1/notes` | v1 REST controller (`api/v1/notes#create`) |
| `POST /note/actions/create_note` | Markdown UI action (`notes#create_note`) |

Both ultimately do the same thing, but the action route is the canonical path:
- The capability system ([app/services/capability_check.rb](app/services/capability_check.rb)) is designed around action names
- The MCP server reference client navigates via the markdown UI and POSTs to action routes
- Permission, scope-downscoping, and immutability work has landed on the action paths more consistently
- AI agent capability gating happens at the action layer

Maintaining two write paths multiplies the surface area where security/UX work has to land twice. As the v1 API ages, this redundancy is starting to look like a liability.

## Decision

**Make the v1 REST API read-only.** All writes must go through the action routes. The v1 API remains useful for structured reads (lists, nested includes, results).

## Scope

### What changes

- v1 controllers narrow to `only: [:index, :show]` plus action-style GETs (e.g. `decisions#results`)
- Routes get updated to remove POST/PUT/PATCH/DELETE
- Removed actions return `405 Method Not Allowed` with `Allow: GET, HEAD` and a body pointing to the equivalent `/actions/...` URL for any clients still sending writes during the deprecation window — OR they simply disappear (route 404), depending on the deprecation strategy chosen
- Help docs (`/help/rest-api`) reduced to read-only documentation; cross-link to `/help/markdown-ui` for writes
- The InfoController's dynamic route list automatically reflects the narrower surface (no extra work)

### What stays

- `GET /api/v1` info endpoint
- `GET /api/v1/notes`, `GET /api/v1/notes/:id`
- `GET /api/v1/decisions`, `GET /api/v1/decisions/:id`, `GET /api/v1/decisions/:id/results`, nested option/participant/vote GETs
- `GET /api/v1/commitments`, `GET /api/v1/commitments/:id`, nested participant GETs
- `GET /api/v1/cycles`, `GET /api/v1/cycles/:id`
- `GET /api/v1/users`, `GET /api/v1/users/:id`
- `GET /api/v1/users/:user_id/tokens`, `GET /api/v1/users/:user_id/tokens/:id`
- `GET /api/v1/collectives`, `GET /api/v1/collectives/:id`
- All `include=` query parameter behavior

### What's lost

- `POST /api/v1/users` (create AI agent) — replace with action route
- `POST /api/v1/notes`, `POST /api/v1/decisions`, `POST /api/v1/commitments` — already have action equivalents
- `POST /api/v1/notes/:id/confirm`, `POST /api/v1/commitments/:id/join` — already have action equivalents
- All decision option/vote/participant write paths — already have action equivalents
- `POST/PUT/DELETE /api/v1/users/:user_id/tokens` — token CRUD via action routes (these exist at `/u/:handle/settings/tokens/...`)

## Implementation outline

1. Audit every v1 controller; verify each write has an equivalent action route. File any gaps as blockers before starting.
2. Switch route definitions: `resources :notes, only: [:index, :show] do; ... end` (and similar)
3. Decide deprecation strategy:
   - **Hard cut**: routes simply 404 / 405
   - **Soft cut**: `before_action` on removed actions returns 405 with a body pointing to the replacement
4. Update tests:
   - Remove or invert all v1 write tests (assert they now return 405/404)
   - Move write coverage to the equivalent action route tests (where it likely already exists)
5. Rewrite `/help/rest-api` to be read-only; add a "writes" section that cross-links to `/help/markdown-ui`
6. Update `docs/API.md` similarly
7. Run the v1 info-endpoint drift test — its dynamic list should reflect the narrower surface automatically

## Open questions

- **Deprecation timeline**: hard cut vs. soft cut with 405 notices? Hard cut is simpler; soft cut is friendlier for any external integration that exists. Probably depends on whether any production users hit v1 writes.
- **AI agent creation via API**: `POST /api/v1/users` is the canonical way an integration would mint a new AI agent. Is there an action route equivalent? If not, this is a gap that needs filling before the cut. (Looking at routes, `ai-agents/new/actions/create_ai_agent` exists — so the action route does cover it.)
- **`decisions#results`**: this is technically a GET on a virtual resource, so it stays. Confirm it's in the "what stays" list.
- **External users**: are there known integrations that hit v1 write endpoints? If yes, ship a deprecation notice ahead of the cut.

## Verification

- All v1 write paths return 405/404 (or the chosen response) and reference the action route
- All v1 read paths still work
- Existing action-route writes still work and are the only path
- v1 info-endpoint drift test passes (proving the new narrower set is what we want)
- `/help/rest-api` no longer mentions writes; `/help/markdown-ui` is referenced for writes
