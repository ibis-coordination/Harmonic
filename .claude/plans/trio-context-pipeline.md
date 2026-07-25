# Trio Context Pipeline

Status: design. The long-term architecture for how Trio produces a
response; the near-term incident work in
[trio-improvements-overview.md](trio-improvements-overview.md) stands on
its own and this grows out of it. Supersedes the "ensemble triage /
two-tier dispatch" idea parked in that doc's set-aside list.

## Motivation

Two observations from the 2026-07-18 mention-loop incident:

1. **Threads outgrow context.** A run in the cascade hit thread
   truncation and its think-step said, verbatim: *"I need to be careful
   not to respond to something I haven't read"* — and then responded
   anyway, justifying it from "the progressive nature of this onboarding
   conversation." Every long thread eventually puts every agent in this
   position: responding to content it can't fully see, at full-context
   prices. The truncation is also why the incident got expensive — each
   run re-read a growing thread.
2. **Three parallel generalists duplicate work.** Each persona
   independently read the same thread cold and decided what to say —
   which is how one mention became 18 near-identical comments. The triad
   framing (doing/verifying/learning) was only expressed in prose, not in
   the shape of the work.

## The idea

Trio organizes as a data pipeline. Before an agent acts, the ensemble
prepares the ground — each stage attributed to the persona whose watch it
is:

| Stage | Persona | Function |
|---|---|---|
| 1. Safety screen | Counterpoint | Check the triggering content for prompt injection / security concerns. Verdict: proceed, proceed-with-advisory, or abort. |
| 2. Context compaction | Cadence | Provide a bounded summary of the thread/context in place of raw history. |
| 3. Plan | Melody | A short step-by-step plan for the response. |
| 4. Execution | whichever persona is responding | Receives summary + plan + advisory (if any) and carries them out. |

Trio stops being three agents who might each speak and becomes a
**process with three named functions**, where "who speaks" is just the
last stage. The public behavior already decided in the overview doc
(melody as main speaker, receipts as default, respond when addressed)
is unchanged — the pipeline is the internal organization behind it.

## Design decisions

### The safety screen runs isolated — not merged into a combined call

The efficiency instinct is to do all prep in one LLM call. For stages
2+3 that's right. Stage 1 must stay separate:

- If one call ingests the untrusted thread and emits verdict + summary +
  plan, a successful injection doesn't just slip past the screen — it
  gets to **author the summary and the plan**, exactly the artifacts the
  executor trusts more than raw content.
- The screen's security value comes from isolation: a small, cheap model,
  a narrow structured output (`safe | unsafe | advisory` + reason),
  no downstream artifacts. Cents per call.
- LLM injection screening is probabilistic either way, but "screen can be
  fooled" and "screen, when fooled, hands the attacker the plan" are
  different failure classes. Buy the isolation.

So: **two calls** — a tiny counterpoint screen, then one combined
cadence+melody call for summary + plan.

An abort still creates a run record (with the verdict) — the abort IS the
observable event; advisory verdicts attach to the executor's context as a
warning it must heed.

### The summary is a persistent artifact, not a per-run step

Per-run summarization still re-reads the whole thread per response — the
cost win evaporates. Instead: an **incremental per-thread chronicle**.
Cadence updates a running summary when the thread grows; every subsequent
run (any persona's) consumes it; nobody re-reads history.

- Cheaper: one update per thread event, shared by all consumers.
- Inspectable: the summary has an author and provenance; if it's wrong,
  it can be audited and corrected — unlike silent truncation.
- Honest: every agent now *explicitly* responds to a summary, rather
  than implicitly responding to a truncated thread. The incident's
  rationalization becomes structurally unnecessary.
- Dual-use: this is the same mechanism as cadence's deferred
  cycle-summary work — build the chronicle once, use it for both.

Open: where the chronicle lives (a Note-like record? a column on the
thread root? an agent-memory table?), visibility (probably
collective-visible — it's a summary of collective content by a collective
agent), and update triggering (evented on comment.created vs batched).

### The plan is advisory scaffolding, not a script

Plans go stale on contact — the page changed, an action failed. A rigid
executor turns a stale plan into confident wrong actions, which is worse
than wandering. The executor treats the plan as scaffolding ("read X,
respond addressing Y, don't do Z"), may deviate or abort-and-replan, and
deviations are visible in the step timeline. For simple mention-replies
the plan is nearly trivial; the stage earns its cost on complex tasks.

### Attribution honesty

Stage *outputs* are attributed to personas as roles (that's the UX and
the audit trail). But if summary+plan come from one call, the run view
says so — no staging three theatrical LLM calls to make the attribution
literal. Costs are billed where the call actually ran (the pool absorbs
either way; per-agent cost attribution follows the actual caller).

### Where the pipeline runs

Leaning: orchestrated by the agent-runner as typed steps on the same
task run (new step types, e.g. `safety_screen`, `context_summary`,
`plan`), reported through the existing step pipeline — so the run
timeline, the visibility work, and lineage all display it with zero new
surfaces. The alternative (Rails-side pre-dispatch pipeline) makes
aborts cheaper (no run dispatched at all) but adds a second orchestration
home. Decide at build time; the isolation requirement (separate screen
call) holds either way.

## What this buys

- **Bounded context** — cost per response scales with summary size, not
  thread length; the truncation failure class disappears.
- **Structural dedup** — one pipeline, one output; the fan-out problem
  is dissolved rather than suppressed by norms.
- **A real job for counterpoint now** — the screen is the verifying
  watch made operational, before moderation features exist.
- **Readable runs** — verdict / summary / plan / steps is an inspectable
  narrative; extends the visibility + lineage work naturally.
- **Injection defense at the right boundary** — screened before the
  acting model ingests untrusted content.

## Staged build order

Each stage ships alone and pays for itself:

1. **Truncation honesty (prompt-only, immediate)** — all personas: "if
   you cannot fully read the content you're responding to (truncation,
   missing thread), do not respond substantively — confirm read or say
   what you couldn't see." Rides with the overview's Track A prompt
   rework.
2. **Cadence's incremental thread chronicle** — the persistent summary
   artifact + runs consume it instead of raw history when present. The
   biggest cost/correctness win, and it doubles as the cycle-summary
   foundation.
3. **Counterpoint's isolated safety screen** — small-model structured
   verdict before execution; abort + advisory paths; verdict on the run
   record.
4. **Melody's plan stage** — combined call with summary refresh where
   sensible; advisory-plan executor semantics.

## Open questions

1. Chronicle storage, visibility, and update cadence (see above).
2. Screen model choice and prompt; what "advisory" injects into the
   executor's context; false-positive handling (an abort the human
   disagrees with should be cheap to override — probably just
   re-mention).
3. Does the pipeline apply to all internal agents or only
   collective-principaled personas? (Leaning: any internal-runtime agent
   opts in via config; personas default on.)
4. Per-stage model config (screen wants small; summary/plan mid; the
   overview's per-rule model tiering idea composes here).
5. How the chronicle interacts with visibility/permissions if per-note
   audiences inside a collective ever tighten (same assumption flagged in
   the visibility doc).
