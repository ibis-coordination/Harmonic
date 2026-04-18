/**
 * Agent Runner — entry point.
 * Consumes tasks from Redis Streams, executes agent loops concurrently via Effect fibers.
 */

import { Effect, Layer, pipe } from "effect";
import { Config, ConfigLive } from "./config/Config.js";
import { LLMClientLive } from "./services/LLMClient.js";
import { HarmonicClientLive } from "./services/HarmonicClient.js";
import { TaskReporterLive } from "./services/TaskReporter.js";
import { TaskQueueLive } from "./services/TaskQueue.js";
import { AgentLockLive } from "./services/AgentLock.js";
import { RailsHttpLive } from "./services/RailsHttp.js";
import { TaskQueue } from "./services/TaskQueue.js";
import { AgentLock } from "./services/AgentLock.js";
import { TaskReporter } from "./services/TaskReporter.js";
import { runTask } from "./services/AgentLoop.js";
import { log } from "./services/Logger.js";

/**
 * Runtime stats for monitoring. Written to Redis periodically
 * and readable from the Rails admin interface.
 */
interface RunnerStats {
  activeTasks: number;
  totalTasksProcessed: number;
  processedSinceStart: { completed: number; failed: number; cancelled: number };
  startedAt: string;
  lastTaskAt: string | null;
  lastCompletionAt: string | null;
  lastFailureAt: string | null;
  lastFailureReason: string | null;
}

const stats: RunnerStats = {
  activeTasks: 0,
  totalTasksProcessed: 0,
  processedSinceStart: { completed: 0, failed: 0, cancelled: 0 },
  startedAt: new Date().toISOString(),
  lastTaskAt: null,
  lastCompletionAt: null,
  lastFailureAt: null,
  lastFailureReason: null,
};

/**
 * Graceful shutdown state. Set by SIGTERM/SIGINT handlers.
 * When true, the main loop stops accepting new tasks and waits for
 * in-flight tasks to finish before exiting.
 */
let draining = false;

/** Active task run IDs — used by XAUTOCLAIM to avoid reclaiming our own in-flight tasks. */
export const activeTaskRunIds = new Set<string>();

const DRAIN_TIMEOUT_MS = 270_000; // 4.5 minutes (within 5 min Docker grace period)

process.on("SIGTERM", () => {
  log.info({ event: "shutdown_requested", signal: "SIGTERM", activeTasks: stats.activeTasks });
  draining = true;
});
process.on("SIGINT", () => {
  log.info({ event: "shutdown_requested", signal: "SIGINT", activeTasks: stats.activeTasks });
  draining = true;
});

/**
 * Main processing loop: read from stream, acquire agent lock, fork task execution.
 */
const processQueue = Effect.gen(function* () {
  const queue = yield* TaskQueue;
  const agentLock = yield* AgentLock;
  const config = yield* Config;

  yield* queue.ensureGroup();

  log.info({ event: "started", maxConcurrent: config.maxConcurrentTasks, streamMaxLen: config.streamMaxLen });

  // Publish stats to Redis periodically
  yield* Effect.fork(publishStatsLoop());

  // Reclaim orphaned stream entries (crash recovery)
  yield* Effect.fork(orphanRecoveryLoop());

  // Process loop — exits when draining is set
  yield* pipe(
    Effect.gen(function* () {
      if (draining) return yield* Effect.fail("drain" as const);

      // Backpressure: don't read new tasks if at concurrency cap
      if (stats.activeTasks >= config.maxConcurrentTasks) {
        yield* Effect.sleep("1 second");
        return;
      }

      const entry = yield* queue.read();
      if (entry === null) return; // Timeout, loop again

      log.info({ event: "task_received", taskRunId: entry.task.taskRunId, agentId: entry.task.agentId, activeTasks: stats.activeTasks });

      const acquired = yield* agentLock.tryAcquire(entry.task.agentId);
      if (!acquired) {
        log.info({ event: "agent_busy_nack", taskRunId: entry.task.taskRunId, agentId: entry.task.agentId });
        yield* queue.nack(entry.id);
        return;
      }

      stats.activeTasks++;
      stats.totalTasksProcessed++;
      stats.lastTaskAt = new Date().toISOString();
      activeTaskRunIds.add(entry.task.taskRunId);

      // Fork task execution — runs concurrently
      // Note: runTask catches all its own errors internally and reports via reporter.complete/fail.
      // The Effect always succeeds at the outer level, returning the outcome for stats.
      yield* Effect.fork(
        runTask(entry.task).pipe(
          Effect.tap((result) =>
            Effect.sync(() => {
              const now = new Date().toISOString();
              stats.processedSinceStart[result.outcome]++;
              if (result.outcome === "completed") {
                stats.lastCompletionAt = now;
              } else if (result.outcome === "failed") {
                stats.lastFailureAt = now;
                stats.lastFailureReason = `task ${entry.task.taskRunId}`;
              }
            }),
          ),
          Effect.ensuring(
            Effect.sync(() => {
              stats.activeTasks--;
              activeTaskRunIds.delete(entry.task.taskRunId);
            }),
          ),
          Effect.ensuring(agentLock.release(entry.task.agentId)),
          Effect.ensuring(queue.ack(entry.id).pipe(Effect.orDie)),
        ),
      );
    }),
    Effect.catchAll((error) => {
      if (error === "drain") return Effect.fail(error);
      log.error({ event: "queue_processing_error", message: String(error) });
      return Effect.void;
    }),
    Effect.forever,
  ).pipe(
    // The loop exits with "drain" error — catch it and proceed to drain wait
    Effect.catchAll(() => Effect.void),
  );

  // Drain: wait for in-flight tasks to complete
  if (stats.activeTasks > 0) {
    log.info({ event: "draining", activeTasks: stats.activeTasks });
    const drainStart = Date.now();
    yield* pipe(
      Effect.gen(function* () {
        while (stats.activeTasks > 0) {
          if (Date.now() - drainStart > DRAIN_TIMEOUT_MS) {
            log.warn({ event: "drain_timeout", activeTasks: stats.activeTasks, activeTaskRunIds: [...activeTaskRunIds] });
            break;
          }
          yield* Effect.sleep("2 seconds");
          log.info({ event: "draining", activeTasks: stats.activeTasks, elapsed: Math.round((Date.now() - drainStart) / 1000) });
        }
      }),
      Effect.catchAll(() => Effect.void),
    );
  }

  log.info({ event: "shutdown_complete", activeTasks: stats.activeTasks });
  yield* queue.shutdown();

  // Exit explicitly. Forked fibers (publishStatsLoop, orphanRecoveryLoop, and
  // any timed-out task fibers) are Effect.forever loops that never complete.
  // Without this, the process would hang after the main fiber returns.
  process.exit(stats.activeTasks > 0 ? 1 : 0);
});

/**
 * Periodically write stats to a Redis key for admin monitoring.
 * Rails can read this from the admin dashboard.
 */
const publishStatsLoop = () =>
  pipe(
    Effect.gen(function* () {
      yield* Effect.sleep("10 seconds");
      const queue = yield* TaskQueue;
      const info = yield* queue.streamInfo();
      yield* queue.publishStats({ ...stats, ...info } as unknown as Record<string, unknown>);
    }),
    Effect.catchAll(() => Effect.void),
    Effect.forever,
  );

const AUTOCLAIM_MIN_IDLE_MS = 120_000; // 2 minutes
const DEAD_LETTER_THRESHOLD = 3;

/**
 * Periodically reclaim orphaned stream entries via XAUTOCLAIM.
 * Handles: process crashes, OOM kills, drain timeouts.
 */
const orphanRecoveryLoop = () =>
  pipe(
    Effect.gen(function* () {
      yield* Effect.sleep("30 seconds");
      if (draining) return;

      const queue = yield* TaskQueue;
      const reporter = yield* TaskReporter;
      const entries = yield* queue.autoClaim(AUTOCLAIM_MIN_IDLE_MS);

      for (const entry of entries) {
        // Skip entries for tasks we're currently running
        if (activeTaskRunIds.has(entry.task.taskRunId)) continue;

        // Dead-letter: if claimed too many times, it's a poison message
        if (entry.deliveryCount >= DEAD_LETTER_THRESHOLD) {
          log.warn({
            event: "dead_lettered",
            taskRunId: entry.task.taskRunId,
            deliveryCount: entry.deliveryCount,
          });
          yield* reporter.fail(
            entry.task.taskRunId,
            entry.task.tenantSubdomain,
            `dead_lettered_after_${entry.deliveryCount}_claims`,
          ).pipe(Effect.catchAll(() => Effect.void));
          yield* queue.ack(entry.id).pipe(Effect.catchAll(() => Effect.void));
          continue;
        }

        // Check task status on Rails
        const status = yield* reporter.getTaskStatus(
          entry.task.taskRunId,
          entry.task.tenantSubdomain,
        ).pipe(Effect.catchAll(() => Effect.succeed("unknown")));

        if (status === "completed" || status === "failed" || status === "cancelled") {
          // Task already reached terminal state — just ACK the stale entry
          log.info({
            event: "autoclaim_already_terminal",
            taskRunId: entry.task.taskRunId,
            status,
          });
          yield* queue.ack(entry.id).pipe(Effect.catchAll(() => Effect.void));
        } else if (status === "running") {
          // True orphan — mark failed
          log.warn({
            event: "autoclaim_orphan_failed",
            taskRunId: entry.task.taskRunId,
          });
          yield* reporter.fail(
            entry.task.taskRunId,
            entry.task.tenantSubdomain,
            "orphaned_after_process_crash",
          ).pipe(Effect.catchAll(() => Effect.void));
          yield* queue.ack(entry.id).pipe(Effect.catchAll(() => Effect.void));
        } else if (status === "queued") {
          // Dispatched but never claimed — the previous runner crashed
          // before processing. NACK re-publishes it as a fresh stream
          // entry for normal XREADGROUP pickup, avoiding the delivery
          // count incrementing toward dead-letter on each XAUTOCLAIM cycle.
          log.info({
            event: "autoclaim_queued_requeued",
            taskRunId: entry.task.taskRunId,
          });
          yield* queue.nack(entry.id).pipe(Effect.catchAll(() => Effect.void));
        } else {
          // Unknown status (e.g. Rails returned an error) — don't ACK.
          // Leave the entry pending so it can be retried on the next cycle.
          log.warn({
            event: "autoclaim_unknown_status_skipped",
            taskRunId: entry.task.taskRunId,
            status,
          });
        }
      }
    }),
    Effect.catchAll((error) => {
      log.error({ event: "autoclaim_error", message: String(error) });
      return Effect.void;
    }),
    Effect.forever,
  );

/**
 * Compose all layers and run the program.
 */
const RailsHttpProvided = RailsHttpLive.pipe(Layer.provide(ConfigLive));

const ServiceLayer = Layer.mergeAll(
  LLMClientLive,
  HarmonicClientLive,
  TaskReporterLive,
  TaskQueueLive,
  AgentLockLive,
).pipe(Layer.provide(ConfigLive), Layer.provide(RailsHttpProvided));

// Config must also be available directly (AgentLoop reads it for token decryption)
const MainLayer = Layer.merge(ServiceLayer, ConfigLive);

const program = processQueue.pipe(
  Effect.provide(MainLayer),
  Effect.tapErrorCause((cause) => {
    log.error({ event: "fatal_error", message: String(cause) });
    return Effect.void;
  }),
);

Effect.runPromise(program).catch((error) => {
  log.error({ event: "process_crashed", message: String(error) });
  process.exit(1);
});
