# Disable Direct Messages with Collective-Principaled Agents

> **Shipped** in PR #517 (merged 2026-07-20): persona DMs disabled in both directions.

## Problem

Any signed-in tenant member can open a DM with any built-in persona on the tenant. The
gate in `ChatsController#find_partner_and_session` admits a human→agent chat when the
agent is the human's own **or when the agent is `system?`** — a blanket bypass that
covers every persona: other collectives' personas and other users' private-workspace
personas alike.

A DM to an internal agent dispatches a full `chat_turn` task run. The sender never pays —
`PayerResolver` charges the persona's funding pool, or a workspace persona's owner's
prepaid balance. Two exposures:

1. **Money**: a non-member can drain a collective's pool, or another user's personal
   balance, by chatting. Only throttles: 20 messages/min per (user, agent), one turn at
   a time per session, the per-agent daily cap.
2. **Confidentiality**: a chat turn runs as the persona with its full credentials. A
   non-member can ask another collective's persona to fetch and summarize that
   collective's private content.

Beyond the missing gate, DMs with collective personas are broken by design:

- **Privacy contradiction.** A chat turn IS a task run — the message is the run's `task`
  field, the steps are the run detail. Admins and automators of the principal collective
  can read every run (shipped deliberately, 1.52.0). So a "private" DM with a collective
  persona is a UI fiction: the chat window looks private while the automation managers
  can read every word. No membership-gated variant of DMs fixes this.
- **Pool trust.** If members can have persona conversations invisible to other members,
  funders cannot see where pool money goes. The trustworthy invariant is: **pool money
  is only ever spent on activity every pool member can see.** Nothing hidden to audit.
- **Scope.** Chat sessions live in their own private chat collective —
  `find_partner_and_session` switches thread context to it. A collective-principaled
  persona acting there operates *outside its principal collective*. The principalship
  model already says that's out of scope; this enforces the boundary that defines what
  these agents are.

## Decision

**Direct messages with collective-principaled agents are disabled entirely, both
directions.** No admin carve-out.

- **Workspace personas keep chat.** Owner-principaled, owner-paid, owner is the only
  viewer of both the chat and the runs — no contradiction, no pool. Chat is their
  primary interface.
- Collective members interact with collective personas only in shared space: notes,
  comments, mentions, automations. All persona activity is visible-to-the-collective by
  construction. If a lightweight "ask the persona" channel is ever needed, it should be
  a shared thread inside the collective, not DMs.
- **Historical human↔persona chat pages 404.** Rows stay in the DB; the run pages are
  the surface we stand behind for that history.

## The rule this all serves

**Pool money is only ever spent on activity every pool member can see.** This is the
baseline rule of pooled funding — enforceable structurally only for built-in agents
today, with tightly scoped consent-gated exceptions as a future mechanism. This slice
both enforces it (for the chat door) and documents it user-visibly for the first time.

## Invariants (statable in one sentence each)

1. A collective-principaled agent never participates in a chat session.
2. A funding pool never pays for a chat turn.
3. A human can DM only agents they are the principal of.

## Implementation

### 1. Controller gate — the chokepoint

`ChatsController#find_partner_and_session` is the single resolution point for every chat
surface (HTML, markdown actions, MCP — the `send_message` action authorization is just
`:authenticated`, so this lookup is the real gate).

- **Human sender, agent partner**: drop the `system?` bypass. Allowed iff
  `current_user.ai_agents.include?(@partner)` — parent-only. Workspace personas pass
  (owner is parent); collective personas cannot (parent is the identity user). 404
  otherwise, consistent with existing handle-privacy behavior.
- **Agent sender**: if `current_user` is a collective-principaled agent
  (`system? && parent&.collective_identity?`), refuse all chat routes. This closes the
  reverse direction — a persona initiating a DM to a member is the same scope violation.
- Historical sessions: no special-casing; the pair fails the gate → 404.

Express the human-side rule as a predicate on User (e.g. `chattable_by?(viewer)` —
naming at implementation) so views can share it.

### 2. Payer + dispatch — enforce invariant 2 independently

A pool-funded agent's chat turn is **refused outright — no fallback to personal
billing**. A fallback would mean a parent chatting with their pool-attached agent gets
silently billed personally for what looks pool-funded (surprise billing). Nobody pays,
because the call doesn't happen; detaching the agent (reverting it to its own billing)
is the sanctioned way to chat with it. If exceptions are ever wanted, they need their
own consent design.

- `PayerResolver#resolve`: `chat_turn` runs never take the pool path; a pool-funded
  agent's chat turn raises `pool_cannot_fund_chat` even with a stamped billing
  customer. Non-pool agents (workspace personas, ordinary own agents) resolve against
  individual billing as normal. Holds regardless of how the run was created —
  independent of the controller-level chat restrictions.
- `AgentRunnerDispatchService`: fail-fast for `chat_turn` + pool-funded with a
  user-readable error, so the turn fails immediately in the chat UI instead of at the
  first LLM call after the runner spins up.

Belt at the controller, braces at the payer, readable error at dispatch.

### 3. UI honesty

- Profile kebab "Message" item (`users/show.html.erb`): render only when
  `@showing_user.chattable_by?(@current_user)` (humans stay chattable as today; agents
  parent-only).
- Chat sidebar (`load_chat_partners`) already lists only `current_user.ai_agents` for
  humans — workspace personas appear (correct), collective personas never did. For
  agent viewers, exclude sessions the agent can no longer access (collective personas
  have no legitimate sessions left).
- Markdown views mirroring these surfaces get the same conditionals.

### 4. Docs — communicate the rule, not just enforce it

The visibility invariant is the trust foundation for pools and has never been stated
anywhere user-visible. Funding pool documentation currently lives shoehorned into
`/help/collectives`; it deserves its own page, and this slice creates it.

**New page: `/help/funding-pools`** (`app/views/help/funding_pools.md.erb`, topic added
to `HelpController::TOPICS` + the routes list, feature-gated the same way the current
pool section is — via the billing topic gate):

- **Lead with the baseline rule, stated as a rule users can rely on**: pool money is
  only ever spent on activity every pool member can see. A funder can open the
  collective and see everything the pool paid for; there is nothing hidden to audit.
- State how it's upheld for built-in agents (the structural case): their principal is
  the collective, they act only in the collective's shared space, they have no direct
  messages, and every task run is inspectable.
- **Be honest about the current exception**: attaching a member's own agent to a pool
  (operator-enabled, admin-only, principal must be enrolled) is not structurally
  covered — that agent's runs are visible to its principal, not to every member. Frame
  the operator + admin + enrollment gates as the current consent mechanism, and note
  the direction: exceptions to the baseline rule will always be tightly scoped behind
  explicit consent gates — the rule is the default, never silently traded away.
- Migrate the rest of the existing pool content (enrollment/withdrawal, draw mechanics,
  ceilings, admin controls, "Funded by" profile line) from `collectives.md.erb`,
  reorganized under the rule-first framing.
- `collectives.md.erb` keeps a short section: one-paragraph summary + link to
  `/help/funding-pools`.

**Cross-links**: `/help/trio` (state that collective personas have no DMs —
interaction happens in shared collective space, which is what keeps pool spending
visible; workspace personas chat with their owner and bill the owner), `/help/billing`
spend-limits section, and the pool page itself if it links to help.

Audience note: help pages are read by agents via `get_help` — third-person factual,
no "you the human" framing.

### 5. Tests (red-green)

Controller:
- Human → other collective's persona: 404 on show and both send surfaces
  (`/message`, `/actions/send_message`); no session, no message, no task run created.
- Member (and admin) of the principal collective → own collective's persona: 404 —
  the disable is total, membership grants nothing.
- Workspace owner → own workspace persona: chat works, turn dispatches (regression).
- Non-owner → someone else's workspace persona: 404 (was allowed via `system?` bypass).
- Human → own user-created agent: unchanged (regression).
- Human → human: unchanged (regression).
- Collective persona as authenticated sender → any chat route: refused.
- Historical session pair (session row exists): still 404.

Payer:
- Chat-turn run for a pool-funded agent: pool never selected; resolution fails (or
  falls to individual billing) with the chat-turn-specific error.
- Non-chat run for the same agent: pool pays (regression).

UI:
- Persona profile for a collective member: no Message item.
- Workspace persona profile for its owner: Message item present.

Help:
- `/help/funding-pools` renders (feature-gated correctly: available where billing help
  is, absent where not), appears in the help index, and states the visibility rule.
- `/help/collectives` links to it; the migrated content is not duplicated.

## Out of scope (noted, not addressed here)

- Human↔human DM policy (unrestricted-but-blockable today).
- Agent→human DMs by non-persona agents (spam vector; separate policy question).
- Profile visibility of agents (read-only; runs/automations links already gated;
  anon-readable tenants expose profiles world-readable).
- Per-sender draw attribution / spend caps (Track C).
- Collective-level group chat — a shared, member-visible conversation surface inside
  the collective could become the sanctioned "talk to the persona" channel (it would
  satisfy the visibility rule by construction). Worth designing later.
