# Decision Semantics & Action Approval

Status: planning. Stage 1 of
[programmable-collectives-and-governance-overview.md](programmable-collectives-and-governance-overview.md).
Ships GitHub issue #378 (approval process for agent/trustee actions) and lays
the decision-semantics foundation that the later governance/policy layer
consumes as configuration.

## Problem

Decisions today are **advisory preference-elicitation instruments**: they
produce a live-computed ranking, not a verdict. Four gaps keep them from
serving as approval/governance mechanisms:

1. **No persisted outcome** — results can shift after the deadline (votes
   edited, options soft-deleted); nothing downstream can safely enforce "this
   passed."
2. **No eligibility** — anyone with access can vote; no declared electorate.
3. **No quorum** — and the participant model can't support one: participants
   are created on *view*, conflating spectators with voters.
4. **No threshold** — acceptance voting ranks options but never draws a
   verdict line ("majority", "⅔", "consent/no objections").

Separately, issue #378: capability grants for agents and trustees are binary
on/off. Wanted: a "with approval" mode where actions are possible but held for
principal review — and eventually a "multiplayer ouija-board" flow where
collective members converge on actions with no single designated
representative.

These are the same problem. An approval is a held action awaiting a decision;
a governance gate is a held action awaiting a *binding* decision. Build the
machinery once.

## What exists (verified)

- **Subtypes** `vote | lottery | executive`
  ([decision.rb:17](../../app/models/decision.rb#L17)) — three legitimacy
  sources: counting, chance, authority. Executive has `decision_maker` /
  `effective_decision_maker`; only they can close/write statements. Lottery
  sorts by verifiable beacon randomness (`lottery_beacon_round` /
  `lottery_beacon_randomness`).
- **Acceptance voting**: per option, each participant sets `accepted` (0/1)
  and `preferred` (0/1) ([vote.rb:25-26](../../app/models/vote.rb#L25)).
- **Results are a DB view** (`decision_results`), live-computed ranking:
  accepted_yes → preferred → lottery_sort_key → random_id
  ([decision_result.rb](../../app/models/decision_result.rb)); `position`
  assigned in memory at read time. Nothing persisted at close.
- **Closing**: `closed?` is just `deadline <= Time.now`
  ([application_record.rb:144](../../app/models/application_record.rb#L144));
  `decision.deadline_reached` automation event fires when a deadline passes.
  Far-future deadline = manual close convention (`requires_manual_close?`).
- **DecisionParticipant is created on view** — `view_count` is
  `participants.count` ([decision.rb:203](../../app/models/decision.rb#L203));
  voters are the subset with votes (`user_has_voted?`, `voter_count`).
- **Audit chain**: `DecisionAuditService` records option/vote/close entries
  with receipts; enabled for decisions created after 2026-05-05.
- **ActionsHelper** ([actions_helper.rb](../../app/services/actions_helper.rb))
  is the single authorization checkpoint for ~100 actions across all surfaces
  (UI, markdown API, MCP, agents, automations). Automation internal actions
  already execute as the collective identity user through it.
- **Commitments** have `critical_mass` and emit `commitment.critical_mass`.
- **Representation/trustee system** exists (`can_represent?`,
  representation sessions); capability grants are binary (per #378).

## Design

### Core reframe: protocol × subject, not new subtypes

Do **not** add `action_selection` as a fourth subtype (contra the sketch in
#378). The existing subtypes answer *how is the outcome determined?*
(counting / chance / authority). *What resolution does* — answer a free-form
question vs. execute a held action — is an orthogonal axis. Keeping them
orthogonal yields a composition table instead of a subtype explosion:

| | free-form question | options carry proposed actions |
|---|---|---|
| **executive** | today's executive decision | principal approves an agent's action (#378 base case) |
| **vote** | today's vote | ouija board: members propose actions, converge, collective identity executes winner |
| **lottery** | today's lottery | sortition over candidate actions/people |

### DecisionResolution — persisted, immutable outcome

Created when a decision closes (deadline job or manual close):

```
DecisionResolution
  decision_id, resolved_at
  outcome: accepted | rejected | no_quorum | tied | expired
  winning_option_ids[]
  tally jsonb                  # frozen per-option counts at close
  electorate_size, voter_count, quorum_met
  audit receipt                # next link in the existing decision audit chain
```

Notes:
- `no_quorum` is **not** `rejected` — governance processes want "lapses
  without prejudice."
- Ties under a threshold: break with the lottery beacon (already built,
  verifiable) or surface `tied` and let the caller decide. Default: `tied`
  outcome; beacon tiebreak opt-in per decision.
- Fixes the mutable-results bug independently of everything else, and gives
  `decision.deadline_reached` automations a real payload.

### Bindingness criteria on Decision (all opt-in)

```
eligibility: open | members | role:<name> | list:<id> | user:<id>
quorum:      { type: absolute | fraction, value: n }   # of electorate, counting VOTERS
threshold:   ranked | majority | fraction(x) | consent(max_objections: k)
```

- **Defaults preserve current behavior**: `eligibility: open`, no quorum,
  `threshold: ranked` (top-ranked wins, advisory). Zero migration for
  existing decisions; bindingness is opt-in.
- **Electorate snapshot at open** (record date): membership changes mid-vote
  don't change the electorate — prevents vote-packing. Snapshot table or
  frozen jsonb of user ids; decide at implementation based on size.
- **Quorum counts distinct eligible voters ÷ electorate size** — never
  `decision_participants` (spectators). The viewer/voter split must be
  explicit in the resolution math.
- **Threshold** maps onto acceptance voting cleanly — accept/object per
  option *is* consent semantics; the threshold just draws the verdict line:
  `majority` = accepted_yes > accepted_no among voters; `fraction(2/3)` =
  accepted_yes ≥ ⅔ of votes cast; `consent` = objections < k (default 0).
- Executive decisions: eligibility-of-one (`user:<principal>`) with authority
  protocol; quorum/threshold generally not meaningful (validate combinations).

### ProposedAction — the held intent

```
ProposedAction
  action_name, params jsonb    # frozen exactly as they will execute
  proposed_by                  # agent, member, automation — the proposal's cause, per identity-glossary.md
  execute_as                   # principal | collective identity user — the acting identity, per identity-glossary.md
  status: pending → approved → executed | denied | expired
  approval_ref                 # polymorphic: Decision or Commitment
  execution_ref                # run / created resources once executed
  expires_at
```

- What is approved is *literally* what runs — no gap between motion described
  and motion executed. Params frozen at proposal time.
- **Commitments as approval vehicles** (per #378's `action_proposal`
  instinct): a decision approves with a quorum of *voters* ("may this
  happen?"); a commitment approves with a quorum of *volunteers* ("this
  happens if enough of us pledge to do it") — critical mass as the approval
  threshold, resuming off `commitment.critical_mass`.
- Execution routes through ActionsHelper as `execute_as`, with the normal
  authorization + audit + resource-tracking path automations already use.

### Three-valued capability grants

Agent/trustee capability grants become `allowed | with_approval | denied`.
A `with_approval` attempt does not fail: it creates a ProposedAction plus its
approval vehicle (default: executive decision, decision_maker = principal,
options = the proposed action) and notifies the principal. Approve → execute;
deny / expire → recorded, nothing runs.

### Option gains optional `proposed_action_id`

An action-bearing option renders the frozen action (name + params) on the
decision page. Resolution of a decision with action-bearing winning options
executes them (subject to `execution: auto | manual` on the decision —
default `manual` outside the approval flow).

## Phases (each independently shippable)

1. **DecisionResolution.** Close job at deadline (+ manual close path) writes
   the resolution, chained into the audit ledger. `decision.deadline_reached`
   payload includes the resolution. No new voting semantics. Backfill: none —
   resolutions exist only for decisions closed after launch (mirror the audit
   chain launch-date pattern).
2. **Eligibility + quorum + threshold.** Schema on decisions, electorate
   snapshot at open, voter-vs-spectator split in resolution math, validation
   of legal combinations, creation-UI + markdown/API surface. Decisions can
   now bind.
3. **ProposedAction + three-valued grants.** Ships #378's principal-approval
   loop using executive decisions (smallest cell of the table). Notification
   + one-click approve UX. Expiry sweep.
4. **Action-bearing options for vote/lottery.** Unlocks the ouija board
   (vote + `options_open: true` + collective-identity execution) and
   sortition-over-actions. Mostly free once phase 3 exists.
5. *(Handoff to the governance layer — separate plan.)* Policies become
   "grant is `with_approval` for everyone, approval vehicle configured with
   this protocol/quorum/threshold."

Red-green TDD throughout per repo convention; resolution math and threshold
evaluation are pure-function candidates with exhaustive unit tests.

## Invariants (load-bearing — do not trade away)

- Resolutions are immutable and audit-chained; votes cannot change an outcome
  after close.
- Electorate is frozen at open; quorum counts voters, never viewers.
- ProposedAction params are frozen at proposal; execution uses exactly the
  approved params, as exactly the declared `execute_as` identity, through the
  ActionsHelper checkpoint.
- `no_quorum` ≠ `rejected` in every consumer.
- Default semantics (open / no quorum / ranked / advisory) are byte-for-byte
  today's behavior.

## Open questions

- **Standing approvals**: "auto-approve similar actions for 24h" — where
  principal-review UX gets real. What is "similar" (action_name? param
  subset?)? Defer past phase 3 but design the grant schema so it can hold a
  standing-approval record.
- **Early resolution**: close before deadline when the outcome is
  mathematically settled (frozen electorate + binary threshold makes this
  computable). Deferred; interacts with vote-editing.
- **Electorate feedback loops**: governance gating `join_collective` means
  the polity controls its own electorate — snapshot timing makes each vote
  well-defined, but sequencing effects deserve thought before the policy
  layer lands.
- **Executive + quorum/threshold combinations**: which are legal? Probably
  validate to eligibility-of-one + no quorum; revisit if "advice process"
  patterns (executive decides after mandatory consultation) are wanted.
- **Vote privacy**: binding votes raise the stakes of vote visibility; current
  visibility model unchanged for now, revisit with the governance layer.
- **Moderation carve-outs**: platform/tenant moderation must never be gated
  behind `with_approval` grants — enumerate exempt actions when the grant
  surface is built.
