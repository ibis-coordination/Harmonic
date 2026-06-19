# Representation as a first-class resource

## Problem

A representation session is one concept, but today it has no single URL. Where you find it depends on how it was created:

| What | Today |
|---|---|
| Your active reps | `/representing` (top-level magic verb) |
| User-rep session | `/u/{handle}/settings/trustee-grants/{grant_id}` |
| Collective-rep session | `/collectives/{handle}/r/{id}` |
| Start a user rep | `POST /u/{handle}/settings/trustee-grants/{grant_id}/actions/start_representation` |
| Start a collective rep | `POST /collectives/{handle}/represent` |
| End a session | `DELETE /representing`, `DELETE /collectives/{handle}/r/{id}`, or the `end_representation` action |
| Trustee grants | `/u/{handle}/settings/trustee-grants` — buried under settings |

The cost of this scatter is concrete:

- **No canonical session URL.** An agent or human handed a session id has to know which lineage produced it before they can read it.
- **Two start paths for one operation.** The `start_representation` action lives at a deep grant-relative path for user reps, and at a totally different surface for collective reps. The agent's MCP path varies by target.
- **Vocabulary thrash.** `represent`, `representing`, `representation`, `start_representation`, `stop_representing`, `stop_representing_user` are six verb forms for two conceptual operations.

## End state

**Principle:** the representation session is the first-class resource. It has one canonical URL regardless of origin. Trustee grants and collective roles are authorization sources — they enable representation but don't own the URL space.

Concretely:

- **`/representations`** — your active + recent sessions. Replaces `/representing`.
- **`/representations/{id}`** — canonical show URL for any session, replacing the dual collective- and grant-relative show paths.
- **`POST /representations/actions/start_representation`** — single start path. Body discriminates the target: `{grant_id: ...}` for user rep, `{collective_handle: ...}` for collective rep. Existing `/collectives/{handle}/represent` becomes a thin alias that calls into the same code, for back-compat.
- **`POST /representations/{id}/actions/end_representation`** — single end path. Replaces the three end variants.
- **Vocabulary settles on `represent`/`representation`.** `representing`/`stop_representing` go away; controller methods follow.

Trustee grants stay where they are (open question below).

## What the agent sees after

| Operation | Before | After |
|---|---|---|
| Find your reps | `fetch_page /representing` | `fetch_page /representations` |
| Read a session | path varied by lineage | `fetch_page /representations/{id}` |
| Start a user rep | `execute_action(/u/{me}/settings/trustee-grants/{g}/.../start_representation)` | `execute_action(/representations, start_representation, {grant_id})` |
| Start a collective rep | `execute_action(/collectives/{c}/...)` | `execute_action(/representations, start_representation, {collective_handle})` |
| End a session | varied | `execute_action(/representations/{id}, end_representation)` |

One tool, consistent path shape, one verb per operation.

## Tasks

1. **Add the `/representations` resource.** New `RepresentationSessionsController` actions (or extend the existing one) for `index` and `show` at the top-level paths. The index shows the caller's reps (active + recent). The show page renders the same content the current collective-relative or grant-relative show pages render today.
2. **Unify the start path.** New `POST /representations/actions/start_representation` endpoint. Accepts `{grant_id}` for user rep and `{collective_handle}` for collective rep. Validates that the caller has authority (grant active and trustee_user == caller, or representative role in the collective). Existing `/collectives/{handle}/represent` and `.../trustee-grants/{id}/.../start_representation` become aliases — same controller method, different routes.
3. **Unify the end path.** `POST /representations/{id}/actions/end_representation`. Existing end paths alias to it. Drops `stop_representing_user` / `stop_representing` from the public route surface.
4. **Update ActionsHelper action-route mappings.** The `start_representation` / `end_representation` action definitions point at the new canonical routes so the MCP frontmatter exposes them at the new paths. The action names themselves stay stable (`start_representation`, `end_representation`).
5. **Back-compat redirects.** Old paths return 301 to the new canonical paths so saved links, agent code with the old URLs, and external integrations keep working. Drop the redirect aliases after a long sunset window (out of scope for this PR).
6. **Drop the duplicate end variants from controllers + routes.** `stop_representing_user`, `stop_representing` — keep model-level logic, kill the controller methods and route entries. Helper methods that humans don't use directly can stay as private model methods.
7. **Update help docs.** `/help/representation` and `/help/agents/representation` reference the new canonical paths. URL examples in code blocks update. The "URL Patterns" section in `/help/representation` lists the new shape.
8. **Update the lifecycle test.** The MCP rep lifecycle test (`test_full_representation_lifecycle_via_MCP`) switches to the new canonical paths — same flow, fewer hops.

## Tests

- All existing rep tests (user-rep, collective-rep, end-of-session, expiry) continue to pass after the controller methods consolidate. Failures here mean the alias is wrong.
- `test/integration/representation_routes_test.rb` (new) — pins the new canonical URLs: `/representations` index, `/representations/{id}` show, the unified start, the unified end. Pins that an old path returns 301 to the new equivalent.
- The MCP lifecycle test exercises the canonical start path with both `{grant_id}` and `{collective_handle}` targets — one test class, two cases.
- Existing `api_representation_test.rb` flows continue green against the new paths (use the redirects).

## Open questions

- **Trustee grants in or out of `/settings/`.** Today they're buried at `/u/{handle}/settings/trustee-grants`. Moving them to `/u/{handle}/trustee-grants` (or `/u/{handle}/grants`) frames them as a first-class authorization, parallel to representation. Keeping them under `/settings/` keeps grants positioned as account configuration — they ARE that, but they're also platform-critical. Lean: keep under `/settings/` for this refactor; revisit if/when the user-facing UX around grants gets a separate pass.
- **`POST /representations` vs. `POST /representations/actions/start_representation`.** The first is REST-idiomatic; the second matches Harmonic's existing action-route convention (`/{resource}/actions/{action_name}`). Lean: action-route, for consistency with the rest of the action surface and so the MCP `execute_action` path shape doesn't have a special case.
- **`/r` shortcut.** Harmonic uses single-letter shortcuts (`/u`, `/n`, `/c`, `/d`). `/r/{id}` would match the convention, but `/collectives/{handle}/r/{id}` already exists for collective sessions. Resolving: either move `/r/{id}` to the top-level (and retire the collective-scoped path), or skip the shortcut and use the full `/representations`. Lean: full `/representations` is fine — the resource is rarer than notes/decisions and clarity wins over brevity here.
- **Display of "who you're representing" in the chrome.** Today there's a banner driven by `/representing`. After the move it reads from `/representations` (or the same session record under the new URL). Cosmetic — no architectural decision pending.

## Not in scope

- Changes to the `RepresentationSession` or `TrusteeGrant` models, schema, or authorization rules.
- Changes to what triggers `RepresentationSessionEvent` creation (audit log behavior stays identical).
- Changes to the existing API header chain (`X-Representation-Session-ID`, `X-Representing-User`, `X-Representing-Collective`) — those continue to work as today.
- Auto-acceptance of principal → agent grants, or any other change to the grant-acceptance flow.
- Removing the redirects from old paths. Sunset is a separate decision after telemetry shows nothing's hitting them.

## Done when

- A representation session has exactly one canonical URL: `/representations/{id}`.
- `start_representation` is one action at one path, with target discriminated by params. Same shape regardless of whether the target is a user or a collective.
- `end_representation` is one action at one path.
- The agent-facing MCP surface shows one shape for representation operations across all targets.
- Old URLs 301 to the new canonical equivalents; nothing breaks.
- The vocabulary in routes, controllers, and help docs settles on `represent` / `representation` consistently.
