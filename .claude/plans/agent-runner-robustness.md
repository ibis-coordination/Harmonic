# Agent-Runner Robustness & Ops Improvements

## Status

Planning. Follow-up to the agent-runner migration (phases 1-4 shipped on
stripe-integration).

## Motivation

The agent-runner migration replaced a 5-thread Sidekiq worker with a Node
service that handles hundreds of concurrent fibers. Throughput is a big
win. But compared to what Sidekiq gave us for free, the current runner
has gaps in three areas:

1. **Durability** — tasks in flight during a crash can be orphaned;
   single transient errors terminate tasks that would previously have
   retried.
2. **Observability** — stdout strings, not structured logs; no
   correlation beyond `task_run_id` appearing by convention; no
   equivalent of Sidekiq Web's dead-job inspection.
3. **Ops controls** — no "retry this failed task" button; no alerting
   on failure-rate spikes; orphan recovery requires running a rake
   task by hand; `totalTasksProcessed` is cumulative-since-process-start
   and doesn't distinguish success from failure.

This plan is the punch list for bringing the new stack back to parity
with the Sidekiq ergonomics we lost, plus some things Sidekiq never
gave us.

## Non-goals

- Adding a retry tier above the LLM itself. LLM failures surface as
  step records the LLM can see and react to; that's by design.
- Re-adding Sidekiq. The concurrency problem the migration solved is
  still real.

---

## Phase 1: Durability

### 1a. Orphan recovery via XAUTOCLAIM

**Problem.** When the runner crashes mid-task, the stream entry it
pulled is in Redis's pending list but never ACK'd. XREADGROUP with
`">"` only returns NEW entries, so on restart the runner never sees
the pending entry. The task row stays `running` in Rails forever.

**Fix.** Add a periodic XAUTOCLAIM loop to `TaskQueue`:

- Every N seconds (e.g. 30), call `XAUTOCLAIM agent_tasks agent_runner
  <consumer_name> <min-idle-time-ms> 0 COUNT 10`.
- For each reclaimed entry: if idle time exceeds a "definitely dead"
  threshold (e.g. 10 minutes), try to process it; otherwise skip.
- Still honor the per-agent lock before running.
- Consider a "giveup after N claims" policy using the stream entry's
  delivery count (XPENDING ... IDLE reports it): after, say, 3 claims
  without successful ACK, move the entry to a dead-letter stream
  (`agent_tasks:dead`) and mark the task row failed with a
  distinguishable reason.

**Rails-side complement.** When XAUTOCLAIM recovers an entry, we may
be re-running a task that already transitioned to terminal state on
the Rails side (e.g. the crash happened during `/complete`'s HTTP
round-trip but Rails persisted the write). The terminal-state guard
we added to the internal controller (`guard_terminal_transition!`)
means the reclaimed run's `/complete` will 409 — that's fine, the
second runner treats a 409 as "someone else finished it, ACK and move
on."

### 1b. Bounded retries on transient Rails errors

**Problem.** A single 500 from Rails on `/complete` (e.g. a Stripe
hiccup during resource tracking, or DB blip) causes the task to be
marked failed in Rails — or worse, leaves Rails in an inconsistent
state. In the Sidekiq world the whole job would retry 25 times with
exponential backoff.

**Fix.** Bounded retries inside `TaskReporter` for the authoritative
writes:

- `/complete`, `/fail`, `/scratchpad`: retry up to 3 times with
  exponential backoff (250ms, 1s, 4s) on 5xx or connection errors.
- Treat 409 (terminal-state conflict) and 4xx generally as permanent
  — don't retry.
- `/step` is best-effort already (we swallow errors); keep that as is
  since step persistence failures don't fail the task.

Apply the same at `/preflight`: a Stripe outage there currently logs
and lets the run proceed — keep that shape, but retry the preflight
HTTP call itself a couple of times.

### 1c. Dispatch-time durability

**Problem.** Dispatch writes to the DB and publishes to Redis as two
separate steps. If Redis is down when the controller action runs, the
DB has a `queued` task but no stream entry; the task never runs unless
someone runs the redispatch rake.

**Fix (simpler):** if `XADD` fails, mark the task failed with a
`dispatch_failed` error so it shows up in the admin page instead of
lurking forever. The existing `fail_task!` path already handles this
shape; just needs the rescue wired in.

**Fix (longer-term):** outbox pattern — dispatch writes a row to an
`agent_task_dispatches` table inside the same transaction as the task
creation, and a background job flushes the outbox to Redis. Eliminates
the dual-write inconsistency entirely. Overkill for current scale; note
as "if we ever see dispatch failures in the wild."

---

## Phase 2: Observability

### 2a. Structured logging

Replace `console.log(\`[AgentRunner] ...\`)` with a thin helper:

```ts
log.info({ event: "task_received", taskRunId, agentId, activeTasks });
```

- JSON-per-line.
- Required fields: `event`, `level`, `timestamp`, plus a
  `task_run_id` (when applicable) and `agent_id`.
- Pino or a hand-rolled 30-line helper — don't need a big dependency.
- Rails-side: tag `Rails.logger` output in the internal controllers
  with `[task_run_id=XYZ]`, matching the runner's id.

### 2b. Per-task correlation in interleaved output

When many tasks run concurrently in one process, `docker logs
agent-runner` is a firehose. With structured logs + `task_run_id`
everywhere, `docker logs agent-runner | grep <id>` gives one task's
story. Even better: adopt Effect's
[`Logger.withSpan`](https://effect.website/docs/observability/logging)
or similar to propagate the task ID implicitly through nested effects
so we don't have to pass it around manually.

### 2c. Better stats

`totalTasksProcessed` as a single integer blending success + failure
isn't useful. Proposed stats shape:

```json
{
  "activeTasks": 0,
  "processSinceStart": { "completed": 0, "failed": 0, "cancelled": 0, "claimed_but_crashed": 0 },
  "startedAt": "...",
  "lastTaskAt": "...",
  "lastCompletionAt": "...",
  "lastFailureAt": "...",
  "lastFailureReason": "...",
  "streamDepth": <XLEN>,
  "streamPending": <XPENDING IDLE>
}
```

Admin page renders each. The existing `totalTasksProcessed` key stays
for backward compat but is deprecated.

### 2d. Admin page: failed-task inspection

`/system-admin/agent-runner` already shows recent runs. Add:

- Filter by status (completed / failed / cancelled / running).
- For each failed run, a one-click "view steps" drawer with the
  `steps_data` timeline rendered more readably than JSON dump.
- Show token usage and billing attribution inline.

### 2e. Alerting hooks

- Publish Rails `SecurityAuditLog` entries for agent lifecycle events
  worth paging on: `agent_task_dispatch_failed`,
  `agent_task_orphan_reclaimed`, `agent_task_dead_lettered`.
- Wire into whatever alerting path is used today (`AlertService`
  already exists for security events).
- Consider a rate-based alert: failure rate over the last 5 minutes
  above a threshold.

---

## Phase 3: Ops controls

### 3a. Retry from the admin page

- Button on a failed task run page: "retry". Creates a new
  `AiAgentTaskRun` copying `task`, `agent_id`, `max_steps`, and
  `initiated_by`, then dispatches. Does not reuse the old run's ID so
  the audit trail stays intact.
- Visible only to `sys_admin` (or the agent owner, if we want to let
  users self-serve).
- Behind a feature flag initially — failed tasks are often failed for
  a reason; we don't want one-click loops.

### 3b. Cancel from the admin page

Today cancel is on `/ai-agents/:handle/runs/:id` for owners. Mirror it
on the admin page so sys_admins can unstick runs without switching
user context.

### 3c. Manual dead-letter replay

If the XAUTOCLAIM "definitely dead" threshold dead-letters an entry,
the admin page should list those and offer "re-enqueue" / "discard"
actions. Similar shape to Sidekiq's Dead set UI.

### 3d. Runbook

`docs/AGENT_RUNNER.md` should grow an "Ops" section covering:

- What to check when tasks stop processing (stream depth, consumer
  group lag, runner heartbeat in stats).
- How to read the runbook entries from structured logs.
- How to trigger orphan recovery manually (rake task stays as a
  fallback even with XAUTOCLAIM automated).
- `AGENT_RUNNER_SECRET` rotation procedure (already written — link
  from here).

---

## Phase 4: Nice-to-haves (if there's time)

- **Tracing.** OpenTelemetry spans for the agent loop, LLM calls, and
  internal API round-trips. Enables distributed debugging once Harmonic
  has more moving pieces.
- **Per-tenant concurrency caps.** Today `MAX_CONCURRENT_TASKS` is
  global. A single runaway tenant can starve everyone else. Add a
  per-tenant semaphore that caps how many tasks from one tenant can
  run simultaneously.
- **Stream key per env.** `agent_tasks` is a fixed name. If ever the
  dev and prod Redis accidentally point at the same instance (unlikely
  but possible), they'd mix. A `ENV`-derived prefix
  (`agent_tasks:<env>`) would be defense-in-depth. Already dodged via
  the test-DB-isolation fix for the dev/test case.

---

## Sequencing

Shortest path to "meaningful win":

1. **Phase 1a + 1b** (orphan recovery + bounded retries) — closes the
   two durability gaps that would most embarrass us in production.
2. **Phase 2a + 2c** (structured logs + useful stats) — tiny code
   change, immediate ops value.
3. **Phase 2d** (admin failure inspection) — user-facing, cheap.
4. Everything else.

## Out of scope

- Switching queue backend (stay on Redis Streams).
- Re-implementing in another language.
- Multi-region agent-runner deployment.
