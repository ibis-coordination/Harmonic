# Representation UX improvements

> Capture of observed friction and bugs in the existing representation surface, both human-side and agent-side, gathered during the Stage 2 live verification. **Not yet a prescriptive plan** — this exists to feed a substantive UX pass after Stage 2 ships.

## Bugs (real defects, not just friction)

🔴 **`/representing` has no markdown template.** Reading the page via an MCP client crashes Rails with `ActionController::UnknownFormat: RepresentationSessionsController#representing is missing a template for this request format`. The agent help page tells agents their active session is at `/representing` (line 78 of `/help/agents/representation`), so the documented discovery path is unreachable for the audience the doc was written for. HTML is fine.

🔴 **`/whoami` under rep renders an empty parenthetical.** The line "You () are currently representing **Dan** (@dan)" appears with literally `()` where the representative's identity should be. A template variable isn't being interpolated. Visible to both human-via-browser and agent-via-MCP.

🟠 **Session-history link points back at the grant, not the session.** The grant page (`/u/{handle}/settings/trustee-grants/{grant_id}`) lists past sessions in a table; each row's session-id link goes to `/u/dan/settings/trustee-grants/{grant_id}` — the grant page itself. No way to navigate to the session-detail view with its action log from there. (User-rep sessions may not even have a dedicated show page; collective-rep sessions are at `/collectives/{handle}/r/{id}`.)

🟠 **Grant page exposes irrelevant actions for the current state.** With status "Active", the page's frontmatter still advertises `accept_trustee_grant` and `decline_trustee_grant` as available actions — both only make sense in "Pending." And `revoke_trustee_grant` is offered to the trustee on the trustee's own view, but only the granting user should revoke.

🟠 **Trustee Grants page wording is backwards on the trustee's side.** The receiver's `/u/{me}/settings/trustee-grants` page shows pending grants under the header "Pending Requests" with text "These users are requesting authority to act on your behalf." The actual semantics: the granting user OFFERS authority to the trustee. From the trustee's perspective, this should read "Trusteeships offered to you" or "[Granting user] is granting you authority to act on their behalf" — the current wording inverts the relationship.

## Agent-side friction

### Discoverability gaps

⚪ **No way for an agent to learn from `/whoami` that grants are pending.** The receiver finds out by knowing to navigate to `/u/{my_handle}/settings/trustee-grants`. No counter, no nudge, no notification. Trustee grants offered to the agent aren't surfaced on the agent's own profile either.

⚪ **`accept_trustee_grant`, `start_representation`, `end_representation` aren't in the default agent capability set.** The principal has to add each one explicitly before the agent can engage with representation. The error when missing is bare ("Your capabilities do not include 'X'") — no hint as to who would add it, where it lives in the agent's settings, or what it does.

⚪ **No "active rep session" signal on `/whoami` when reading as self.** During an active session, fetching `/whoami` with no context blocks the read entirely (see below). Fetching with `viewing_as` context returns the represented user's whoami, not the agent's. So there's no MCP path to "show me my own identity and tell me if I currently have an active rep session." Agents who lose track have to navigate to the grant page to discover their own state.

⚪ **`start_representation` response embeds the session id in human-prose markdown.** The agent has to parse `"Session ID: `<uuid>`"` from a markdown blob to extract the id for subsequent calls. A structured `result` field in the response frontmatter, or a dedicated `_meta.session_id`, would let agents grab the id reliably.

### Active-session friction

🟠 **An active rep session blocks all self-acting reads.** Once a session is open, `fetch_page` with no `context` block returns 403 "Active representation session exists. Include X-Representation-Session-ID header to act as trustee, or end the session first." This is the existing rep flow's defense against ambiguity — but in practice it forces an agent into one of two patterns:
- Thread `context` (rep declaration) into every read for the duration of the session, even when the agent wants to check something about itself.
- End the session, do the self-acting work, restart the session.

Neither is good. The agent's mental model has to handle "I currently have an active session" as global state, which they can't easily inspect (see the `/whoami` gap above). For chat agents handling mixed work, this is a significant friction.

The 403 message names the active session id helpfully, but doesn't suggest the recovery: "if you want to read as yourself, omit the context block AND end the session first."

⚪ **Capability gate fires before MCP context validation.** When the agent's capabilities don't include the action, they get the bare capability error even if their context is also malformed. They have to fix the capability before they can iterate on the context shape. Probably correct priority for security, but worth noting.

⚪ **Singleton-per-user constraint isn't discoverable until you trip it.** "Start a second session and you'll be told to end the first" is what the help page says, but the agent can't find out "do I have an active session right now?" before attempting to start one — they'd have to scrape multiple grant pages to check.

### Information loss on attribution

🟠 **Note history line drops the representative.** The metadata block on `/collectives/{handle}/n/{id}` says `created_by | Claude Code Primary on behalf of Dan` — both halves present. The History section right below reads `Dan created this note at {time}` — the representative is gone. Same data, two different surfaces, inconsistent shape. Agents reading the history will lose the audit-trail half.

⚪ **`/notifications` may not surface "an agent just acted on your behalf."** Didn't probe this directly but worth pinning: when the rep flow attributes a write to Dan, does Dan get a notification that his agent posted? Dan as a participant in the collective would see the post, but the "your agent did something" signal is the principal's accountability hook.

## Human-side friction

### Discoverability gaps

⚪ **No discoverable path to offer trusteeship to an agent.** A human creating a grant for an agent has to navigate `/u/{me}/settings/trustee-grants/new` and know to type the agent's handle as trustee. The agent's profile page doesn't surface "Offer trusteeship to this agent" as an action, even when the viewer is the agent's principal.

⚪ **No "current reps" page for a granting user.** Dan can see grants he's created (and their statuses), but there's no "who is currently representing me right now?" view. The session table on each grant shows it per-grant; there's no consolidated dashboard.

### Grant-creation flow gaps

⚪ **Capabilities on grant creation are an all-or-nothing checklist.** From the grant page I saw 17 capabilities granted (`vote, pin_note, ..., create_commitment, update_decision_settings, ...`). UX for narrowing this is unclear — does the principal pick individually, or is there a default set? If individually, this is tedious; if default, hard to inspect what was actually selected.

🟠 **The action-capabilities list in the new grant view is incomplete.** The capabilities offered when creating a grant don't cover the full set of actions an agent might need — notably the representation-related capabilities themselves (`accept_trustee_grant`, `start_representation`, `end_representation`) aren't selectable, which is why a principal can create a grant for an agent and then watch the agent fail to engage with it. The set should at minimum include every action the model treats as `GRANTABLE_ACTIONS` plus the rep lifecycle actions; missing entries silently drop functionality without surfacing what was excluded.

⚪ **Collective Scope is shown as "All collectives" with no UI evidence that scoping is possible.** The model supports `{mode: "include", collective_ids: [...]}` and `{mode: "exclude", ...}`. Unclear how the creator narrows scope, and unclear from the grant page that the scope is even configurable.

### Notification gaps

🟠 **The represented user gets no notification when a session occurs.** A representation session opens, actions are taken on the represented user's behalf, the session ends — and the only signal to the represented user is whatever the actions themselves produced (a new note in a feed, a vote on a decision). To learn that a session HAPPENED, the represented user has to navigate to `/u/{me}/settings/trustee-grants/{grant_id}` and notice a new row in the session-history table. The principal accountability story breaks here — a human granting trustee authority to an agent has no inbox-style trail of "your agent did X, Y, Z on your behalf." Every session should emit a notification (probably one per session, summarizing the actions, rather than one per action) so the represented user has a continuous record they didn't have to dig for.

🟠 **No way to inspect what happened in a given session.** The session-history table on the grant page lists each session as a row, but the session-id link points back at the grant page itself (see also the bug under Bugs above). So even if the represented user notices a new session, they have no way to see what actions were taken during it. The activity log lives on the `RepresentationSession` model (`representation_session_events`), but the show page for it isn't reachable from the human-facing nav. Without this, "transparency for the represented user" is just an assertion in the help docs — operationally there's nothing to read.

### Banner / live-state UI

⚪ **The rep banner on every page says "Logged in as Dan, acting on behalf of Dan."** Once you understand the model this parses, but at first read it's confusing — you're "logged in as Dan" AND "acting on behalf of Dan" simultaneously. The first reads like an identity statement, the second like a delegation. For an agent representing Dan, this should probably read "Logged in as Claude Code Primary, acting on behalf of Dan" — the *agent's* identity is the constant, the represented user is what changes per session.

## Vocabulary and naming

⚪ **`/representing` is the verb-as-noun-route.** Inconsistent with the rest of Harmonic's noun-based URL conventions. The follow-up plan [`representation-routes-refactor.md`](representation-routes-refactor.md) addresses this — calls out `/representations` as the first-class resource path.

⚪ **`trustee-grants` is internal vocabulary.** A human reading the page sees "Granting User," "Trustee," "Capabilities," "Collective Scope." All accurate, none particularly user-friendly. "You can let someone act on your behalf" might be more inviting than "Trustee Grant: X on behalf of Y."

## Themes / clusters

- **Agents can't introspect their own representation state via MCP.** /representing crashes, /whoami doesn't signal active sessions, and there's no "list my pending and active reps" tool.
- **Pages don't filter their action list by current state.** Same problem as the help-topics-discovery plan but on the action surface — actions advertised that no longer apply.
- **The grant-acceptance flow is unfriendly to agents.** Requires three capabilities to be granted upfront just to engage with representation at all, and there's no in-band path for the agent to ask for those capabilities or for the principal to set them up alongside the grant offer.
- **Information about who is acting fragments across surfaces.** Metadata vs. history vs. notifications vs. session log — each shows a different slice, none shows the full picture (representative + represented + grant + session).
- **The verb thrash is across more than just routes.** "Representing," "representation," "represent," "trustee," "granting" — five distinct surface vocabularies for one set of concepts.

## Out of scope for this capture

- Prescriptive solutions or specific implementation plans. This document is a problem inventory.
- The model layer (RepresentationSession, TrusteeGrant, capability checks). Whatever changes ship here should not require schema changes.
- Specific copy rewrites. Naming alternatives mentioned above are illustrative, not committed.

## Related plans

- [`representation-routes-refactor.md`](representation-routes-refactor.md) — already-captured plan to elevate representation to a first-class URL resource. Solves some of the discoverability and verb-thrash issues at the URL layer.
- [`help-topics-discovery-refactor.md`](help-topics-discovery-refactor.md) — orthogonal but related: the documented discovery path for agents only works if agents can find the docs reliably.
