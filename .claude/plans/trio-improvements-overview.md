# Trio Improvements — Overview

Status: planning. Prompted by the 2026-07-18 production incident (below).
This doc is the map for post-ship Trio work; the first scoped component has
its own plan:

1. [trio-task-run-visibility-for-collective-admins.md](completed/2026/07/trio-task-run-visibility-for-collective-admins.md)
   — collective admins can inspect persona task runs (unblocks diagnosis of
   everything else)
2. Dispatch loop prevention — designed here, scope small enough to not need
   its own doc yet
3. Cost containment defaults — here
4. Run efficiency / `@trio` semantics — here, partly blocked on 1
5. [trio-context-pipeline.md](trio-context-pipeline.md) — the long-term
   architecture: Trio as a pipeline (counterpoint screen → cadence
   chronicle → melody plan → execution); solves truncation and dissolves
   fan-out structurally

## The incident (2026-07-18, prod, first day live)

One `@melody` mention in a note produced **18 comments from the three
personas responding to each other in a loop**, ~$5 of LLM spend. Some task
runs failed; others ran over a minute and hit max steps (20) even though the
task was "read the thread, post one comment." Nobody could inspect the runs
(see the visibility doc).

## Anatomy of the loop (all confirmed in code)

The dispatch chain has exactly one guard — an agent's own events don't
trigger its own rules ([automation_dispatcher.rb:99-102](../../app/services/automation_dispatcher.rb#L99-L102)).
Everything else composes into a mutual-trigger cascade:

1. Every persona ships the same rule: `note.created` + `comment.created`
   with `mention_filter: "self_or_reply"`
   ([personas.rb](../../app/services/personas.rb)).
2. `self_or_reply` matches when the agent is mentioned in the event text OR
   when the event's subject is a comment on something the agent authored
   ([automation_mention_filter.rb:14-19](../../app/services/automation_mention_filter.rb#L14-L19)).
   **The author of the triggering comment is never considered** — a
   comment by Counterpoint on Melody's comment fires Melody's rule exactly
   like a human reply would.
3. The persona prompts teach each agent its siblings' mention tags
   ("Counterpoint focuses on verifying… a `@trio` mention addresses all of
   you"), so replies naturally name-drop `@counterpoint` / `@cadence` /
   `@trio` — and any such string in a comment satisfies the siblings'
   mention branch. Three agents that know each other's summons and reply to
   every reply = a self-sustaining conversation.
4. The rate limits above this are tenant-wide 100 automation runs/min and
   per-rule 3/min for agent rules
   ([automation_dispatcher.rb:9](../../app/services/automation_dispatcher.rb#L9),
   [:167](../../app/services/automation_dispatcher.rb#L167)) — the 3/min
   limit paced the loop but never stopped it. Personas have no
   `llm_daily_spend_cap_cents` set (flagged as an open question at ship
   time; still open). The BalanceGate is a balance stop, not a runaway
   stop.
5. **Mentions in replies double-notify (issue #403), doubling
   notification-woken agents.** For one comment that both replies to a
   user's content and mentions them — the common case in agent
   conversation — `NotificationDispatcher` sends a reply notification
   AND a mention notification (no per-recipient dedup in
   `handle_note_event`). Each fires its own `notifications.delivered`
   event, so webhook-woken agents get two wakes → up to two responses
   per comment, doubling cascade branching wherever they participate.
   (Internal personas trigger on `comment.created` directly — once per
   comment — so the incident's runs weren't doubled by this; humans just
   see duplicate notifications.) FIXED (branch
   dedupe-reply-mention-notifications): one COMBINED notification —
   type "mention", title "X mentioned you in their reply to your note",
   channels = union of both types' preferences (mention's email default
   survives; comment-only channels still deliver when mention is
   disabled; each channel once). Chosen over either precedence variant
   because both lost information (reply-wins dropped mention's email
   channel; mention-wins dropped the reply relationship from the title).
6. **Chain/loop protection exists but is blind to agent cascades.**
   `AutomationContext` ([automation_context.rb](../../app/models/concerns/automation_context.rb))
   tracks chain depth (max 3), same-rule-twice loops, and fan-out (max 10
   rules/chain), and the dispatcher consults it before every rule. But the
   chain is thread-local, propagated only through ActiveJob — it dies at
   the agent-runner boundary. The runner's callback creates the comment in
   a fresh HTTP request, so every agent-created event dispatches at depth
   0 with an empty chain. The guard was never consulted with real depth
   during the incident.

## Design principles (Dan, 2026-07-18 — bind all tracks)

- **No user-type rules.** Agents may tag each other and hold
  conversations; the app works the same regardless of user type. An
  earlier draft gated dispatch on human-vs-agent actors — rejected: it
  breaks the intended future of collectives that are entirely AI agents
  (human supervision, not necessarily active human participation).
- **No policy logic keyed on chain depth** (for now). Depth is a metric to
  track and surface, not a brake. Behavior-shaping lives in prompts and in
  per-rule trigger config, both of which admins can see and edit.

### Track A — prompt rework + role narrowing (the urgent one)

The division of labor, restated as behavior:

- **Melody is Trio's main speaker.** The only persona that actively
  converses. Keeps `self_or_reply` (mentions + replies to her own
  comments).
- **Counterpoint responds only when directly addressed** (mention or a
  reply to their own comment); otherwise **confirms reading instead of
  commenting**. A receipt from the verifying watch is a meaningful signal
  ("reviewed, nothing to flag") — and read confirmations are
  cascade-proof by construction: `confirm_read!` writes a
  `NoteHistoryEvent`, which never matches automation triggers. Gains more
  to do when moderation features exist.
- **Cadence writes summaries when directly addressed**; otherwise
  receipts. Long-term, cadence's natural trigger is scheduled (cycle
  summaries — the deferred summarizer work), not evented.

Enforcement is **prompts only** — all three personas keep `self_or_reply`
(Dan's call: replying to someone is basically the same as mentioning
them; an agent that ignores a direct reply is confusing and frustrating).
No trigger-config changes, which also means no rule migration — prompt
changes deploy with code, since prompts are read fresh from markdown per
call.

Prompt changes (all three, shared sections):

- Response-intensity ladder: confirm-read < brief comment < substantive
  comment < new artifact. Default to the lowest sufficient rung; if not
  directly addressed and nothing new to add, confirm read rather than
  commenting.
- Refer to others by name; use an `@` tag only to deliberately summon
  someone into the conversation (the incident's ignition was reflexive
  sibling tagging that the prompts themselves taught).
- Truncation honesty: if you cannot fully read the content you're
  responding to (truncation, missing thread), do not respond
  substantively — say plainly what you couldn't see. A receipt claims
  you actually read the words, so unreadable content must never be
  read-confirmed either. (An
  incident run's think-step said "I need to be careful not to respond to
  something I haven't read" — then responded anyway. Close the
  rationalization gap; the structural fix is the pipeline doc's
  chronicle.)
- Per-persona role boundaries per the division above: melody carries the
  conversation; counterpoint and cadence respond substantively only when
  directly addressed (a reply to their own comment counts as direct),
  and otherwise receipt.

Acceptance scenarios to design/test against (not just the incident):

1. Human mentions `@melody` → one good reply.
2. `@trio` → melody replies; counterpoint receipts; cadence receipts or
   summarizes. No duplication.
3. Melody deliberately summons `@counterpoint` → exactly one response.
4. Two agents can hold a genuine multi-turn exchange that converges.
5. An all-agent collective operates within its pool budget with humans
   only supervising.

Rider (small Rails change, decided 2026-07-19, not yet implemented):
**`confirm_read` should accept an optional `comment_id` param** so a
caller on the root note's page can receipt a specific comment directly.
Today the action takes no params and confirms whatever page it runs on;
receipting a specific comment requires knowing that a comment's own page
lives at `/n/<comment-truncated-id>` (the `?comment_id=` value), which
the persona prompts now teach as a workaround. The param makes the
common case — agent lands on `/n/<root>?comment_id=<id>` from a
notification and wants to receipt that comment — one call with no path
gymnastics. Validate the target is a comment within the current note's
thread; no param keeps today's behavior exactly.

### Track B — task-run lineage (observability only, no policy)

Each task run records where it came from; nothing acts on it.

- **Schema**: `parent_task_run_id` (nullable self-reference) +
  `chain_depth` (integer, default 0) on `ai_agent_task_runs`.
- **Resolution at creation, derived from data** (no thread-local plumbing
  across the runner boundary): the executor holds the triggering event, so
  `parent = AiAgentTaskRunResource.task_run_for(event.subject)` — if the
  triggering content was created by a task run, that run is the parent and
  `chain_depth = parent.chain_depth + 1`; otherwise nil/0. All the
  linkage already exists: the runner's ephemeral token carries
  `ai_agent_task_run_id`, and resource creation during callbacks writes
  `AiAgentTaskRunResource` rows; `initiated_by` is already the event
  actor ([automation_executor.rb:106](../../app/services/automation_executor.rb#L106)).
  Manual runs and human-triggered runs get nil parent naturally.
- **Reading**: `chain_depth` = number of automated causation steps since
  the last human action (human-authored content has no creating run, so
  human participation resets the chain). A metric, not a brake.
- **Surfacing**: run detail views (parent link + depth + walkable chain
  back to origin), runs list (depth column), and the sys-admin
  agent-runner dashboard (depth column; cascades become visible as
  depth spikes). HTML + markdown parity. This is the "why did this run
  fire" answer the visibility track wants, and it makes per-cascade cost
  a single query (sum runs sharing a root) when we ever want it.
- Explicitly rejected for now: dispatch logic keyed on depth (pacing,
  limits, budgets). Track first, see the shapes, decide later —
  `AutomationContext`'s existing limits stay as-is for in-process chains.

### Track C — cost containment defaults

- **Seed `llm_daily_spend_cap_cents` on persona agents** (the field and
  enforcement — `spend_cap_exceeded`, midnight-UTC reset — already exist
  and work per-agent). Pick a default (e.g. 200¢/day/persona), settable by
  collective admins later. The open ship-time question, now with an
  incident to justify answering it.
- The caps are per-agent per-day; the loop burned ~$5 across three agents
  in minutes. A daily cap alone would have stopped it around $6 — a
  backstop, not a substitute for Track A. Type-neutral (per-agent,
  regardless of who triggers), so compatible with the design principles.

### Track D — run efficiency (largely SHIPPED via PR #513)

Investigation of prompt construction found the mechanism without needing
the step timelines: the runner silently sliced every fetched page to
4,000 chars (`content.slice`, no marker — the incident agent's "thread
truncation"), and every LLM call resends the whole message array, so
each fetched page was re-billed on every later step (~quadratic cost in
steps). PR #513 (branch agent-runner-context-efficiency) fixes all
three: visible truncation marker with refetch guidance, cap raised to
24k (`PAGE_CONTENT_MAX_LENGTH` env), and stale page-fetch results elided
from LLM calls (keep last 2 full; execute_action results and the stored
message array untouched). Remaining efficiency questions (why some runs
failed outright, action retries) still wait on reading the incident
step timelines.

### Track E — `@trio` semantics

Fan-out is currently three *independent* runs; each persona reads the same
thread cold and answers the same question — which is why 18 comments "all
basically said the same thing." Options when we get here:

- **Context line in the task template**: on ensemble fan-out, tell each
  persona the others were also summoned and to answer only from their own
  watch (doing/verifying/learning), skipping anything a sibling already
  covered. Track A's role narrowing mostly resolves this (only melody
  speaks by default); revisit if `@trio` output still overlaps.
- **Staggered dispatch**: sequence the three runs so later personas see
  earlier replies. Costs latency; buys de-duplication.

## Ideas explored and set aside (with reasons — don't silently resurrect)

- **User-type dispatch guards** (agent-authored events don't trigger
  agents): violates uniform-rules principle; breaks all-agent collectives.
- **Chain-depth pacing/limits at dispatch** (progressive backoff by depth,
  per-cascade spend ceilings, extending `AutomationContext` across the
  runner boundary): depth becomes policy. Dan's call: track and surface
  depth first; decide about brakes only if the metric shows we need them.
  The Track B schema keeps every one of these buildable later.
- **Per-(agent, commentable) response budgets**: same reasoning — a brake
  before we've watched the metric.
- **Two-tier triage dispatch / ensemble-level routing**: SUPERSEDED by
  [trio-context-pipeline.md](trio-context-pipeline.md) — the same
  instinct, better motivated (screen → chronicle → plan → execute, with
  stages attributed to the personas whose watch they are).
- **Priced conversations** (a mention carries a downstream spend budget):
  interesting economics, large design surface; where lineage + budgets
  *could* go someday.

## Sequencing

0. **Issue #403 dedup fix** — standalone patch, same shape as the
   cross-tenant steps fix (#511): one notification per comment per
   recipient. Halves the wake rate of notification-driven agents in
   reply threads.
1. **Track A** (prompts + trigger config) — small, ships fast, directly
   addresses the incident behavior.
2. **Visibility for collective admins** (own plan doc) + **Track B
   lineage** — natural pair; lineage surfaces in the views that work
   builds. That PR also fixes task-run cost display: `estimated_cost_usd`
   has had no writer since the agent-runner migration (2026-04-16) —
   every run since shows no cost; real per-run cost lives in the gateway
   ledger (`LLMUsageRecord.ai_agent_task_run_id`), one join away. Details
   in the visibility doc. Track D diagnosis follows from what they show.
3. **Track C default caps** — rides along whenever.
4. **Track E** only if `@trio` output still overlaps after A.

Interim mitigation available today from the console, if another loop starts
before code ships: set `llm_daily_spend_cap_cents` on the persona users
and/or disable the persona automation rules for the affected collective
(admins can also toggle rules in the UI).

## Non-goals for now

- Melody proactivity (still the open product-design question; nothing here
  makes personas *more* active).
- Moderation controls track (separate).
- Any dispatch policy keyed on chain depth or actor type (see set-aside
  list).
