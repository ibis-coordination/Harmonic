# Stateless agent interface (MCP server + agent-runner + Rails)

## Problem

Both agent-facing clients are **stateful**: performing an action requires a prior
`navigate` call that sets a "current location" cursor in the client process's own memory.
`execute_action` operates on wherever that cursor points. Note the cursor lives in the
**MCP server / agent-runner processes**, not in Rails — the Rails backend is already
stateless (a `navigate` GET returns markdown and Rails stores nothing about location).
The one exception is the agent-runner's chat mode, which persists `current_path` to the
Rails DB between turns and replays it; that is the agent-runner persisting its own cursor,
not Rails maintaining one.

- MCP server: [mcp-server/src/handlers.ts](mcp-server/src/handlers.ts) keeps `State = { currentPath }`.
  `execute_action` errors with "No current path. Call 'navigate' first." if the cursor is unset
  ([handlers.ts:99-104](mcp-server/src/handlers.ts#L99-L104)), then rebuilds the action URL as
  `{currentPath}/actions/{action}`.
- Agent-runner: [agent-runner/src/services/AgentLoop.ts](agent-runner/src/services/AgentLoop.ts)
  keeps `currentPath` / `currentContent` / `currentActions` / `lastActionResult` in memory,
  validates the action against `currentActions`, and **replays the previous turn's navigation**
  between chat turns solely to keep that validation passing.

This hidden precondition confuses agents. The cursor is also **redundant**: the markdown a
read already returns embeds the fully-qualified action URLs
(`[`vote(votes)`](/collectives/team/d/abc123/actions/vote)`, from
[app/views/shared/actions_index.md.erb](app/views/shared/actions_index.md.erb) /
[app/helpers/markdown_helper.rb:38](app/helpers/markdown_helper.rb#L38)). The state machine
reconstructs a URL the agent already holds.

## Goal

Make the agent interface **stateless**. Every tool call is self-contained; there is no
"current location." The Rails API becomes fully self-describing (path + content + controls +
param schemas + honest status codes), which is what lets the clients become thin pass-throughs.

### Non-goals

- No change to the human HTML interface.
- No change to authentication, scopes, or the capability/authorization model.
- Not rewriting the 172 explicit `describe_*`/`execute_*` action routes into a generic
  dispatcher. We add a **fallback**, we don't replace the per-action routes.

## Conceptual model: browser session → hypermedia

Today's model is a **browser session** — a cursor you move with `navigate`, actions operate on
wherever it points. The target is the **hypermedia model** (REST as intended): every response is
a self-contained representation that embeds its own controls (action URLs + param schemas); you
invoke a control by its path. No cursor. Harmonic's markdown is *already* a hypermedia document,
so this removes a fiction rather than adding machinery.

## Settled decisions

1. **Action addressing: `(path, action, params)`.** `execute_action` gains an explicit `path`;
   `action` + `params` stay as today. (Rejected: passing the full `action_url` — keeps action a
   named first-class concept and avoids URL-splitting.)
2. **Drop client-side action validation.** Rails is the sole authority. (Requires Tier 1 below —
   without it, agents get *more* confused, not less.)
3. **Rename `navigate` → `fetch_page`.** The rename signals there is no location. Pairs as
   `fetch_page` (read) + `execute_action` (write). `search` / `get_help` stay as thin wrappers,
   minus the cursor side-effect.

## Two facts that make Tier 1 a prerequisite (not an enhancement)

Both were masked by client-side validation; dropping it exposes them.

1. **Unknown action → bare Rails 404.** 172 explicit `actions/` routes, **no catch-all**
   ([config/routes.rb](config/routes.rb)). A guessed/typo'd action name 404s with a generic page
   and no hint of what *was* valid. There is currently no Rails-side equivalent of the
   client-side validation we're removing.
2. **Action errors return HTTP 200.** `render_action_error`
   ([app/controllers/application_controller.rb:1265](app/controllers/application_controller.rb#L1265))
   sets no status, and **no call site passes one** (~125 callers across 14 controllers). A *failed* action returns `200 OK`;
   the MCP server's `response.ok` check ([handlers.ts:143](mcp-server/src/handlers.ts#L143)) sees
   success and passes the error body through as a normal result. It only "works" because the
   agent eyeballs `# Action Error`. This becomes load-bearing once Rails is the only feedback.

---

## Work

Sequenced so the interface is never in a broken intermediate state. **Red-green TDD throughout:
write the failing test first.**

### Phase 1 — Rails: honest status codes (Tier 1, prerequisite)

Today every md/json action response is `200` regardless of outcome — a default that was never
deliberately chosen for the agent API, just inherited. The stateless MCP client can't branch on
that; it has to peek at the body for `# Action Error`, which is brittle.

- `render_action_error` returns a real status for `md`/`json`: `422` (bad/missing params),
  `403` (unauthorized), `404` (unknown action/resource), `409` (conflict). Keep success `200`.
  Plumb an optional `status:` local (default `422`) so call sites can specify; success stays `200`.
- **Audit existing call sites** (~125 across 14 controllers) and assign 403/404/409 where the
  error message clearly signals one of those classes; leave the rest defaulting to 422. Without
  this, "honest status codes" only distinguishes failure from success — the agent can't tell
  "fix your params" from "you don't have permission," which is worse than today's 200-with-body
  (the body at least carries class info in its text). The audit is mostly mechanical message-pattern
  matching.
- Tests: controller/request tests asserting status code per error class on `.md` responses; a
  test that a successful action stays `200`.

### Phase 2 — Rails: teaching errors for unknown/unauthorized actions (Tier 1, prerequisite)

This is the **direct substitute** for the client-side validation we're dropping — centralized,
always current, recovers in one shot.

- Add a fallback so `POST /{path}/actions/{unknown}` returns `404` whose **body is the action
  index for that path** (reuse `ActionsHelper.actions_for_route` — single source of truth).
  Message: "`{unknown}` is not a valid action at `{path}`." plus a listing.
- Implementation note: a single global catch-all `*url_prefix/actions/:unknown_name` (GET+POST)
  at the bottom of `config/routes.rb` after the explicit routes, dispatching to
  `ApplicationController#unknown_action_fallback`. The handler uses
  `Rails.application.routes.recognize_path` to resolve the prefix back to a `controller#action`
  and `ActionsHelper.route_pattern_for` to find the matching actions list.
- **Deferred to a follow-up: 403 + available-actions list for unauthorized-but-defined actions.**
  When an action IS defined for the resource type but the user isn't authorized, the explicit
  handler runs and returns 403 (from Phase 1). Appending the available-actions list to that 403
  would be useful but requires either changing each authorization-rejection site or extracting a
  shared `available_actions_for_current_route` call into `render_action_error` — neither is small.
  In practice this case is rare: Phase 5's stateless markdown already filters the shown actions
  to authorized-only, so the agent shouldn't try unauthorized ones. Punted; the 404 catch-all
  covers the common case (typo, hallucinated name, action defined elsewhere).
- Tests: unknown action name → `404` + lists valid actions; a valid action still routes to its
  explicit handler (no regression); GET to an unknown `describe_*` also handled.

### Phase 3 — Rails: self-describing responses (Tier 2, ergonomics)

- **Explicit `path:` field** in every page/action response (frontmatter), sourced from the
  existing `resource.path`. Serves decision #1 — the agent reads the canonical path directly
  instead of splitting an action URL at `/actions/`.
- **Return the updated representation on success.** `render_action_success`
  ([action_success.md.erb](app/views/shared/action_success.md.erb)) renders the full re-rendered
  representation of the **invoked `path`** (the page the action was posted to) with fresh action
  links — the same body `fetch_page` returns — not just `"Note created."` + a link. Collapses
  act→read into one call.
- **Default = re-render the invoked path; callers may pass `redirect_to:` to point elsewhere.**
  `render_action_success` already accepts a `redirect_to:` local for the HTML path; extend its
  semantic to md/json. Used by destructive actions: `delete_note` passes the collective path,
  since `/n/abc` no longer resolves after success. No per-class branching in the framework — the
  per-action decision lives in the controller, one line.
- **Size control: default full re-render with a response-level cap (~8KB), opt into brief via
  `?brief=true`.** Returning the representation is only worth the round-trip-saved if it's actually
  useful — if the default is brief, agents will re-fetch anyway and we've gained nothing. The cap
  prevents pathological pages (long comment threads, large notes indexes) from blowing the context
  window. Implementation: response-level truncation distinct from the existing per-content
  `truncate_content` helper, which operates on individual content blobs supplied by views.
- Creates are the one sub-case that *also* has a freshly-made resource in hand — link to (or
  return) the new resource's page in addition to re-rendering the invoked page.
- Tests: response includes a `path:` field; a mutating action's success body re-renders the
  invoked page with fresh action links; a destructive action (`delete_note`) returns the parent
  via `redirect_to:`; `create_note` additionally surfaces the new note; `?brief=true` returns a
  compact body; oversize responses are capped.

### Phase 4 — MCP server: go stateless

- Delete `State` / `createState` / the `currentPath` plumbing
  ([handlers.ts:13-20](mcp-server/src/handlers.ts#L13-L20)).
- `handleNavigate` → `handleFetchPage(path)` (pure GET, no state write). Rename the registered
  tool `navigate` → `fetch_page` in [mcp-server/src/index.ts](mcp-server/src/index.ts); update its
  description.
- `handleExecuteAction(path, action, params)`: build `{path}/actions/{action}` from the **passed
  path**; drop the "No current path" guard; keep the query-string / `/actions` suffix
  normalization. Branch on HTTP status (now honest) instead of only `response.ok`.
- `search` / `get_help` stop touching state (they already only delegate).
- Update tool descriptions in `index.ts` (remove "You must call navigate first") and
  `mcp-server/CONTEXT.md`.
- **Add MCP `readOnlyHint` to `fetch_page` / `search` / `get_help` and `destructiveHint` to
  `execute_action`.** Now honest (the cursor side-effect is gone). Low cost, enables
  harness-level auto-allow of reads.
- Tests ([handlers.test.ts](mcp-server/src/handlers.test.ts)): `execute_action` works with no
  prior fetch; URL built from passed `path`; error status surfaces `isError: true`. Remove the
  now-obsolete "navigate first" tests.

### Phase 5 — agent-runner: go stateless

- Drop `currentActions` and the `validateAction` gate; drop `currentPath`/`currentContent`/
  `lastActionResult` as *state* (last result already lives in the message history).
- **Delete the chat-turn navigation-replay** (AgentLoop.ts ~lines 252-265) and the
  `currentState.current_path` persistence — no longer needed once actions carry their own path.
- `executeAction` takes `path` from the model's tool call and posts to Rails; surface Rails'
  teaching-error body verbatim on failure.
- Update the system prompt ([agent-runner/src/core/AgentContext.ts](agent-runner/src/core/AgentContext.ts)):
  rename `navigate`→`fetch_page`; remove "Always navigate before executing actions" / "Only
  actions listed for the current page will work" (lines 28, 46, 167-171, 177-183); explain
  `(path, action, params)` and that every response carries its own action URLs.
- Tests ([agent-runner/src/services/AgentLoop.test.ts](agent-runner/src/services/AgentLoop.test.ts)):
  action succeeds without a preceding navigate in the same turn; chat turn 2 can act on a resource
  from turn 1 without replay; invalid action surfaces the Rails 404 body. Remove the
  client-side-rejection test.

### Phase 6 — docs

- [docs/AGENT_RUNNER.md](docs/AGENT_RUNNER.md), `mcp-server/CONTEXT.md`, and any `/help` markdown
  that describes "navigate then act."
- CHANGELOG.

---

## Sequencing & safety

- **Phases 1–2 must land before Phase 5** (and before 4 if 4 drops the client guard). They are
  the trade for deleting client-side validation: without honest status codes + teaching errors,
  a stateless client fails opaquely.
- Phases 1–3 (Rails) are independently shippable and backwards-compatible with today's stateful
  clients — a stateful client tolerates a richer success body and honest status codes fine.
- Phases 4 and 5 are independent of each other (separate clients) once Rails is ready.

## Tradeoffs / risks

- **Lost client-side pre-flight validation** → replaced by Phase 2 teaching errors (better:
  centralized, always current). Risk only if Phase 2 slips.
- **Hallucinated action URLs** (agent guesses `/actions/delete`) → Rails rejects via auth +
  teaching `404`. Security was never client-side; only error quality changes.
- **Larger action responses** (Phase 3 returns full representation) → token cost; mitigated by
  the ~8KB response cap and the `?brief=true` opt-out.
- **Agent threads `path` every call** → path is always in recent context; explicit `path:` field
  (Phase 3) removes the URL-splitting step.
- **"Currently viewing X" observability in chat** → keep as a *display* derived from the last
  fetch step; do not let it gate actions.

## What this deletes (the win)

- Agent-runner: the navigation-replay hack, `currentActions` validation, `currentState.current_path`
  persistence, and the `currentPath`/`currentContent`/`lastActionResult` state vars.
- MCP server: the entire `State` type and "navigate first" guard.
- A latent footgun: `search` setting the cursor to a `/search?q=…` page, so a following
  `execute_action` would post to the search page.
- The single-mutable-cursor bug: today fetch A → fetch B makes A un-actionable; statelessness
  lets an agent reason about two resources at once.
