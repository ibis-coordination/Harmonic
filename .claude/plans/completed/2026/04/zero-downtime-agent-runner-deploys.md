# Zero-Downtime Agent Runner Deploys

## Status

Completed 2026-04-17. All phases shipped on `agent-runner-improvements` branch.

### What shipped

**Phase 1 — Graceful shutdown:**
- SIGTERM/SIGINT signal handlers with task-level drain (4.5 min timeout)
- `stop_grace_period: 5m` on both Docker compose files
- Explicit `process.exit()` after shutdown (forked Effect fibers don't stop on their own)

**Phase 2 — Orphan recovery:**
- XAUTOCLAIM loop (every 30s, 2-min idle threshold) with active-task guard,
  dead-lettering after 3 claims, NACK for queued tasks
- `getTaskStatus` on TaskReporter for Rails status checks
- `OrphanedTaskSweepJob` (Sidekiq cron, every 10 min, 15-min threshold)

**Phase 3 — Docs:**
- DEPLOYMENT.md: Agent Runner section
- AGENT_RUNNER.md: Ops: Graceful Shutdown & Orphan Recovery section

**Infrastructure:**
- Redis port-mapped in dev compose for integration tests
- Integration tests: clean SIGTERM exit + drain with active tasks

### Edge cases handled during review
- Queued tasks NACKed (re-published) instead of left pending to avoid
  premature dead-lettering from XAUTOCLAIM delivery count
- Unknown Rails status skipped (not ACK'd) to avoid dropping tasks on
  transient errors
- `process.exit()` added to prevent process hang from `Effect.forever` fibers

## Motivation

Every deploy that touches the agent-runner container (`docker compose up -d`)
kills the process immediately. Docker sends SIGTERM, waits 10 seconds
(the default `stop_grace_period`), then SIGKILL. Agent tasks can run for
minutes. Any task in-flight at deploy time is orphaned: the stream entry
stays in Redis's pending list (un-ACK'd because `queue.ack` is in
`Effect.ensuring` on the forked task, which never fires on kill) and the
`AiAgentTaskRun` row stays `running` in the database forever. The only
recovery is a manual rake task.

This means routine deploys cause data loss. The goal is: **deploys
complete with no permanently orphaned tasks and no manual intervention.**

## Approach: Task-Level Drain + Orphan Recovery

**Graceful shutdown (SIGTERM):** On SIGTERM, stop accepting new tasks
and let in-flight tasks finish naturally. With a 5-minute Docker grace
period, most tasks complete. The queue backs up briefly during the drain
— acceptable at current scale.

**Hard crash (OOM, SIGKILL):** Tasks can't finish, so we need automated
recovery. XAUTOCLAIM reclaims orphaned stream entries, and a Rails
sweep catches anything XAUTOCLAIM misses. Orphaned tasks are marked
`failed` with a clear reason so users know to retry.

**Future enhancement (not in scope):** Step-level drain with conversation
reconstruction and automatic task resumption. This would eliminate all
data loss, even on hard crash, by rebuilding the LLM conversation from
persisted step data. Deferred until the simpler approach proves
insufficient. Design notes preserved in git history.

## Architecture Overview

```
SIGTERM received
  │
  ├─ Set draining=true (stop reading new tasks from stream)
  │
  ├─ In-flight tasks: continue running to natural completion
  │
  ├─ Wait for activeTasks → 0 (up to 4.5 min, within 5 min grace period)
  │
  ├─ If timeout: log warning, exit (remaining tasks become orphans)
  │
  └─ Disconnect Redis, exit cleanly

Meanwhile (always running):
  ├─ XAUTOCLAIM loop: reclaim orphaned stream entries every 30s
  │   └─ Marks orphaned tasks failed, dead-letters poison messages
  └─ Rails sweep job: catch stuck "running" tasks every 10 min
```

---

## Phase 1: Graceful Shutdown (Task-Level Drain)

### 1a. Shutdown signal handler in index.ts

- Listen for SIGTERM and SIGINT.
- Set a module-level `draining` boolean flag.
- The `Effect.forever` read loop checks `draining` at the top of each
  iteration. When true, break out of the loop instead of reading.
- After the loop exits, wait for `stats.activeTasks === 0` by polling
  every second, with a 4.5-minute timeout (leaving 30s headroom inside
  the 5-minute Docker grace period).
- If timeout expires, log a warning with the IDs of still-running tasks.
  Those tasks become orphans — XAUTOCLAIM (Phase 2) handles them.
- Call `queue.shutdown()` to disconnect Redis cleanly.
- Call `process.exit(0)`.

```ts
let draining = false;

process.on("SIGTERM", () => {
  log.info({ event: "shutdown_requested", signal: "SIGTERM", activeTasks: stats.activeTasks });
  draining = true;
});
process.on("SIGINT", () => {
  log.info({ event: "shutdown_requested", signal: "SIGINT", activeTasks: stats.activeTasks });
  draining = true;
});
```

In the main loop, replace `Effect.forever` with a conditional that
breaks when draining:
```ts
// Instead of Effect.forever:
Effect.repeat(
  Effect.gen(function* () {
    if (draining) return yield* Effect.fail("drain");
    // ... existing read/process logic
  }),
)
```

**The drain wait must happen inside the Effect**, after the loop exits
but before the generator returns. `Effect.runPromise(program)` resolves
when the main fiber completes — forked fibers (`Effect.fork(runTask)`)
continue running in the background, but the process would exit. Keeping
the main fiber alive inside `processQueue` keeps `Effect.runPromise`
pending, which keeps the process alive:

```ts
// Inside processQueue, after the loop breaks:
const DRAIN_TIMEOUT_MS = 270_000; // 4.5 minutes
const drainStart = Date.now();
yield* Effect.gen(function* () {
  while (stats.activeTasks > 0) {
    if (Date.now() - drainStart > DRAIN_TIMEOUT_MS) {
      log.warn({ event: "drain_timeout", activeTasks: stats.activeTasks });
      break;
    }
    log.info({ event: "draining", activeTasks: stats.activeTasks });
    yield* Effect.sleep("2 seconds");
  }
});
log.info({ event: "drain_complete", activeTasks: stats.activeTasks });
yield* queue.shutdown();
```

### 1b. Docker compose: increase stop_grace_period

Both `docker-compose.yml` and `docker-compose.production.yml`:

```yaml
agent-runner:
  stop_grace_period: 5m
```

5 minutes matches the drain timeout. Agent tasks typically complete in
1-3 minutes. Only exceptionally long tasks (many steps, slow LLM) would
hit the timeout.

### 1c. Mark timed-out tasks as failed (not stuck forever)

If the drain timeout expires and tasks are still running, they'll be
killed by Docker's SIGKILL. Without intervention, those rows stay
`running` forever. Two mechanisms handle this:

1. **XAUTOCLAIM (Phase 2a)** — reclaims the pending stream entry and
   marks the task failed on the next runner startup.
2. **Rails sweep (Phase 2b)** — catches any that XAUTOCLAIM misses
   (e.g., if the stream entry was somehow lost).

No code needed in Phase 1 for this — Phases 2a and 2b cover it.

---

## Phase 2: Orphan Recovery

### 2a. XAUTOCLAIM loop in TaskQueue

Add a periodic `Effect.fork`'d loop that runs alongside normal
processing (every 30 seconds):

```ts
XAUTOCLAIM agent_tasks agent_runner <consumer> <min-idle-ms> 0 COUNT 10
```

- `min-idle-ms`: 120000 (2 minutes). If an entry has been pending for
  2+ minutes without ACK, it's likely orphaned.

  **Important:** XAUTOCLAIM's idle time measures time since last
  delivery (XCLAIM/XREADGROUP), not since last activity. There is no
  implicit refresh — once XREADGROUP delivers an entry, its idle time
  grows continuously. A 5-minute task has 5 minutes of idle time. To
  avoid reclaiming entries for tasks that are still actively running
  in this process, maintain a `Set<string>` of active task run IDs
  (add on fork, remove in `Effect.ensuring`). When XAUTOCLAIM returns
  an entry, check the Set first — if the task_run_id is active, skip
  it (don't ACK, don't process, let it stay pending).

- For each reclaimed entry that is NOT active in this process:

  **Step 1: Check delivery count (dead-lettering).** XAUTOCLAIM returns
  the delivery count for each entry. If count >= 3, the entry has been
  claimed multiple times without successful completion — it's likely a
  poison message. Mark the task `failed` via `/fail` with error
  `"dead_lettered_after_3_claims"`, ACK the entry, and move on. This
  prevents infinite retry loops for genuinely broken tasks.

  **Step 2: Check task status on Rails.** Call a new lightweight endpoint:
  ```
  GET /internal/agent-runner/tasks/:id/status
  ```
  Returns `{ status: "running" | "completed" | ... }`.

  **Step 3: Handle based on status.**
  - If terminal (`completed`, `failed`, `cancelled`): just ACK. The
    task finished via another path (e.g., the runner called `/complete`
    before crashing, but crashed before ACK).
  - If `running`: a true orphan. Mark it failed via `/fail` with error
    `"orphaned_after_process_crash"`. Then ACK.
  - If `queued`: dispatched but never claimed. Re-process it as a new
    task (feed into `runTask` normally, which handles preflight/claim).

### 2b. Rails orphan sweep (belt and suspenders)

Add a scheduled Sidekiq job (`OrphanedTaskSweepJob`) that runs every
10 minutes:

- Find `AiAgentTaskRun` rows with `status: "running"` and
  `started_at < 15.minutes.ago`
- Mark them `failed` with error `"orphaned_timeout"` and set
  `completed_at` to now
- Log each one for visibility

15 minutes is conservative: no task should legitimately run this long
(max_steps * ~30s per step = ~15 min at 30 steps). The sweep is a
safety net — XAUTOCLAIM should catch most orphans within 2-3 minutes.

This job handles cases XAUTOCLAIM can't:
- The stream entry was already ACK'd but the task row wasn't updated
  (crash between ACK and /complete — unlikely given the ensuring order,
  but possible)
- Redis was wiped or the stream was deleted
- The runner never started after a crash

---

## Phase 3: Deployment Docs & Ops

### 3a. Update DEPLOYMENT.md

Add an "Agent Runner" section:

```markdown
### Agent Runner

The agent-runner container handles SIGTERM gracefully: it stops accepting
new tasks and waits up to 5 minutes for in-flight tasks to complete.

Standard deploys (`docker compose up -d`) trigger this automatically.
During the drain window, new tasks queue in Redis and are processed by
the new container once it starts.

If the runner is killed before tasks finish (OOM, timeout), orphaned
tasks are automatically detected and marked failed within ~15 minutes.
Users see the failure and can retry.
```

### 3b. Update AGENT_RUNNER.md ops section

Document:
- How graceful shutdown works (task-level drain)
- How XAUTOCLAIM recovers orphans from hard crashes
- How the Rails sweep catches anything XAUTOCLAIM misses
- How to check for orphaned tasks:
  `AiAgentTaskRun.where(status: "running").where("started_at < ?", 15.minutes.ago)`
- The redispatch rake task still exists as a manual fallback

### 3c. Admin UI updates

- Show `orphaned_after_process_crash` and `orphaned_timeout` errors
  distinctly from normal failures (different badge or icon)
- These errors should make it obvious the task can be retried

---

## Recovery Matrix

| Scenario | Mechanism | User impact |
|----------|-----------|-------------|
| Normal deploy (SIGTERM) | Task-level drain — tasks finish naturally | None (queue backs up briefly) |
| Long task during deploy | Drain timeout → XAUTOCLAIM on next startup | Task marked failed, user retries |
| OOM / SIGKILL | XAUTOCLAIM within ~2 min of next startup | Task marked failed, user retries |
| Runner bug (crash loop) | Dead-lettering after 3 claims | Task marked failed, user retries |
| Redis wiped / stream lost | Rails orphan sweep within ~15 min | Task marked failed, user retries |
| Task stuck (infinite loop) | Rails orphan sweep within ~15 min | Task marked failed, user retries |

## Sequencing

1. **Phase 1 (graceful shutdown + Docker grace period)** — the
   critical fix. Covers the common case: normal deploys. Ship first.

2. **Phase 2 (orphan recovery)** — handles hard crashes and edge
   cases. Ship immediately after Phase 1.

3. **Phase 3 (docs & ops)** — parallel with either phase.

## Estimated Complexity

| Phase | Effort | Risk |
|-------|--------|------|
| 1a. Signal handler + drain loop | Small | Low — well-understood Node.js pattern |
| 1b. Docker grace period | Trivial | None |
| 2a. XAUTOCLAIM loop + dead-lettering | Medium | Medium — must avoid reclaiming active tasks |
| 2b. Rails orphan sweep | Small | Low — simple query + update |
| 3. Docs & UI | Small | None |

Total: ~200-300 lines of new code. Mostly in TaskQueue.ts (XAUTOCLAIM),
index.ts (signal handler), and one new Sidekiq job.

## Notes

**Agent lock is in-memory** (`AgentLock.ts` uses a `Set`, not Redis).
Dies with the process, so no stale-lock problem on crash. No changes
needed.

**Step persistence is best-effort.** `addStep` catches errors from
`reporter.step()` and continues. Steps may exist in memory but fail
to persist. On hard crash, in-progress step data is lost. This is
acceptable — the task is marked failed and the user retries.

**XAUTOCLAIM active-task guard is critical.** Without it, a long-running
task (>2 min) could have its stream entry reclaimed while still
executing, leading to a duplicate run or premature failure marking.
The guard (checking against a Set of active task IDs) prevents this.

## Future: Step-Level Recovery

If the simple approach proves insufficient (e.g., tasks are frequently
long-running and deploys cause too many failures), the next step is:

1. Enrich think steps with `tool_calls` and navigate/execute steps with
   `tool_result` so the LLM conversation is reconstructable from
   steps_data
2. Add an `interrupted` status and step-level drain (stop between steps
   instead of waiting for full completion)
3. Build a conversation reconstruction function and resume path
4. Interrupted tasks auto-resume on the next startup

This eliminates all data loss but adds ~500 lines and significant state
machine complexity. Defer until needed.
