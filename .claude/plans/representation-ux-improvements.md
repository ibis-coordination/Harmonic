# Representation UX improvements — remaining items

Problem inventory for the representation surface, scoped to items not yet shipped and not covered by other plans. Not a prescriptive plan — feeds the next UX pass.

> **Already shipped on `representation-ux-bug-fixes` (merged into main):** `/representing` markdown crash, `/whoami` empty parenthetical, "Pending Requests" inverted wording, terminology sweep ("trustee grant" → "trustee authorization" across UI, URL paths, action names), drop of the active-session gate (self-acting reads now succeed), markdown-layout warning surfacing unattached open sessions, 1-hour session lifetime (was 24h), singleton-active-session enforcement at session start.
>
> **Folded into [`representation-routes-refactor.md`](representation-routes-refactor.md):** session show page + activity log inspection, "current reps" dashboard for granting users, session-history link target, per-session notification to the represented user, `/representing` verb-route refactor.

## Bugs

🟠 **Grant page exposes irrelevant actions for the current state.** With status "Active", the page's frontmatter still advertises `accept_trustee_authorization` and `decline_trustee_authorization` as available actions — both only make sense in "Pending." And `revoke_trustee_authorization` is offered to the trustee on the trustee's own view, but only the granting user should revoke. A state-aware filter exists at `trustee_grants_controller.rb` (`action_available_for_grant?`) and is wired into `actions_index_show`, but the show-page frontmatter renders independently and bypasses it.

## Agent-side friction

### Discoverability gaps

⚪ **No way for an agent to learn from `/whoami` that authorizations are pending.** The trustee finds out by knowing to navigate to `/u/{my_handle}/settings/trustee-authorizations`. No counter on `/whoami`, no nudge, no notification when an authorization is created. Authorizations offered to the agent aren't surfaced on the agent's own profile either.

⚪ **`accept_trustee_authorization`, `start_representation`, `end_representation` aren't in the default agent capability set.** The principal has to add each one explicitly before the agent can engage with representation. The error when missing is bare ("Your capabilities do not include 'X'") — no hint that the principal can add it at `/ai-agents/{handle}/settings`.

⚪ **`start_representation` response embeds the session id in human-prose markdown.** The agent has to parse `"Session ID: \`<uuid>\`"` from a markdown blob. A structured `result` field in the response frontmatter, or a dedicated `_meta.session_id`, would let agents grab the id reliably.

## Information loss on attribution

🟠 **Note history line drops the representative.** The metadata block on `/collectives/{handle}/n/{id}` says `created_by | Claude Code Primary on behalf of Dan` — both halves present. The History section right below reads `Dan created this note at {time}` — the representative is gone. Same data, two surfaces, inconsistent shape. Agents reading the history lose the audit-trail half.

## Human-side friction

### Discoverability gaps

⚪ **No discoverable path to offer trusteeship to an agent.** A human creating an authorization for an agent has to navigate to `/u/{me}/settings/trustee-authorizations/new` and know to type the agent's handle as trustee. The agent's profile page doesn't surface "Offer trusteeship to this agent" as an action, even when the viewer is the agent's principal.

### Grant-creation flow gaps

⚪ **Capabilities on authorization creation are an all-or-nothing checklist.** From the show page there can be 17+ capabilities granted. UX for narrowing the set is unclear — does the principal pick individually, or is there a default set? If individually, this is tedious; if default, hard to inspect what was actually selected.

🟠 **The action-capabilities list on the new authorization view is incomplete.** Two distinct surfaces are conflated here (the per-grant `TrusteeGrant::GRANTABLE_ACTIONS` for in-session permissions vs. the agent's overall `CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS` configuration). A principal can create an authorization for an agent and then watch the agent fail to engage with it because the agent's overall capabilities don't include the rep lifecycle actions. The creation flow should surface this dependency, ideally by allowing the principal to also enable the required agent-side capabilities from the same flow.

⚪ **Collective Scope is shown as "All collectives" with no UI evidence that scoping is possible.** The model supports `{mode: "include", collective_ids: [...]}` and `{mode: "exclude", ...}`. Unclear how the creator narrows scope, and unclear from the authorization page that the scope is even configurable.

### Banner / live-state UI

⚪ **The rep banner on every page says "Logged in as Dan, acting on behalf of Dan."** Once you understand the model this parses, but at first read it's confusing — you're "logged in as Dan" AND "acting on behalf of Dan" simultaneously. For an agent representing Dan, this should read "Logged in as Claude Code Primary, acting on behalf of Dan" — the *agent's* identity is the constant, the represented user is what changes per session.

## Vocabulary

⚪ **`trustee-authorization` is still internal-feeling.** A human reading the page sees "Granting User," "Trustee," "Capabilities," "Collective Scope." All accurate; "You can let someone act on your behalf" might be more inviting than "Trustee Authorization: X on behalf of Y." (Pure copy work; defer until the surrounding UX settles.)

## Themes

- **Agents can't introspect their own representation state via MCP outside of the rendered warning.** The markdown-layout warning surfaces open sessions, but `/whoami` itself doesn't tell the agent about pending authorizations. (Adjacent to the routes-refactor work — `/representations` index can carry pending authorizations too.)
- **Pages don't filter their action list by current state.** Same problem as the help-topics-discovery plan but on the action surface — actions advertised that no longer apply. The grant-page action-list state filter is the visible instance.
- **Information about who is acting fragments across surfaces.** Metadata vs. history vs. notifications vs. session log — each shows a different slice, none shows the full picture. The note-history-line attribution fix is one instance; the routes-refactor work picks up the session-log + notification slices.
- **The authorization-acceptance flow is unfriendly to agents.** Requires three capabilities to be granted upfront just to engage with representation at all, and there's no in-band path for the agent to ask for those capabilities or for the principal to set them up alongside the authorization offer.

## Out of scope for this capture

- Prescriptive solutions or specific implementation plans.
- Model-layer changes (RepresentationSession, TrusteeGrant, capability checks). Whatever ships here should not require schema changes.
- Specific copy rewrites.

## Related plans

- [`representation-routes-refactor.md`](representation-routes-refactor.md) — `/representations` as a first-class resource, with the session show page, dashboard, and end-of-session notification work folded in.
- [`help-topics-discovery-refactor.md`](help-topics-discovery-refactor.md) — adjacent: the documented discovery path for agents only works if agents can find the docs reliably.
- [`handle-model-unification.md`](handle-model-unification.md) — bigger restructuring of how user and collective handles relate; touches some of the vocabulary above.
