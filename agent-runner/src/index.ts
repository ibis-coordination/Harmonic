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
import { runTask } from "./services/AgentLoop.js";

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
 * Main processing loop: read from stream, acquire agent lock, fork task execution.
 */
const processQueue = Effect.gen(function* () {
  const queue = yield* TaskQueue;
  const agentLock = yield* AgentLock;
  const config = yield* Config;

  yield* queue.ensureGroup();

  console.log(`[AgentRunner] Started. max_concurrent=${config.maxConcurrentTasks} stream_maxlen=${config.streamMaxLen}. Listening for tasks...`);

  // Publish stats to Redis periodically
  yield* Effect.fork(publishStatsLoop());

  // Process loop
  yield* pipe(
    Effect.gen(function* () {
      // Backpressure: don't read new tasks if at concurrency cap
      if (stats.activeTasks >= config.maxConcurrentTasks) {
        yield* Effect.sleep("1 second");
        return;
      }

      const entry = yield* queue.read();
      if (entry === null) return; // Timeout, loop again

      console.log(`[AgentRunner] Received task ${entry.task.taskRunId} for agent ${entry.task.agentId} (active=${stats.activeTasks})`);

      const acquired = yield* agentLock.tryAcquire(entry.task.agentId);
      if (!acquired) {
        console.log(`[AgentRunner] Agent ${entry.task.agentId} busy, NACKing task ${entry.task.taskRunId}`);
        yield* queue.nack(entry.id);
        return;
      }

      stats.activeTasks++;
      stats.totalTasksProcessed++;
      stats.lastTaskAt = new Date().toISOString();

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
            Effect.sync(() => { stats.activeTasks--; }),
          ),
          Effect.ensuring(agentLock.release(entry.task.agentId)),
          Effect.ensuring(queue.ack(entry.id).pipe(Effect.orDie)),
        ),
      );
    }),
    Effect.catchAll((error) => {
      console.error(`[AgentRunner] Queue processing error: ${String(error)}`);
      return Effect.void;
    }),
    Effect.forever,
  );
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
    console.error("[AgentRunner] Fatal error:", cause);
    return Effect.void;
  }),
);

Effect.runPromise(program).catch((error) => {
  console.error("[AgentRunner] Process crashed:", error);
  process.exit(1);
});
