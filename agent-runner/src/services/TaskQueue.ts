/**
 * Redis Streams consumer for task dispatch — Effect service.
 * Reads tasks from the agent_tasks stream using consumer groups.
 */

import { Context, Effect, Layer } from "effect";
import { Redis as IORedis } from "ioredis";
import { Config } from "../config/Config.js";
import { RedisError } from "../errors/Errors.js";
import type { TaskPayload } from "../core/PromptBuilder.js";
import { log } from "./Logger.js";

export interface StreamEntry {
  readonly id: string;
  readonly task: TaskPayload;
}

export interface StreamInfo {
  readonly streamDepth: number;
  readonly streamPending: number;
}

export interface TaskQueueService {
  readonly read: () => Effect.Effect<StreamEntry | null, RedisError>;
  readonly ack: (entryId: string) => Effect.Effect<void, RedisError>;
  readonly nack: (entryId: string) => Effect.Effect<void, RedisError>;
  readonly ensureGroup: () => Effect.Effect<void, RedisError>;
  readonly publishStats: (stats: Record<string, unknown>) => Effect.Effect<void, RedisError>;
  readonly streamInfo: () => Effect.Effect<StreamInfo, RedisError>;
  readonly shutdown: () => Effect.Effect<void>;
}

export class TaskQueue extends Context.Tag("TaskQueue")<TaskQueue, TaskQueueService>() {}

function parseStreamEntry(fields: string[]): TaskPayload | null {
  const map = new Map<string, string>();
  for (let i = 0; i < fields.length; i += 2) {
    const key = fields[i];
    const value = fields[i + 1];
    if (key !== undefined && value !== undefined) {
      map.set(key, value);
    }
  }

  const taskRunId = map.get("task_run_id");
  const encryptedToken = map.get("encrypted_token");
  const task = map.get("task");
  const agentId = map.get("agent_id");
  const tenantSubdomain = map.get("tenant_subdomain");

  if (
    taskRunId === undefined ||
    encryptedToken === undefined ||
    task === undefined ||
    agentId === undefined ||
    tenantSubdomain === undefined
  ) {
    return null;
  }

  const maxStepsStr = map.get("max_steps");
  const maxSteps = maxStepsStr !== undefined ? parseInt(maxStepsStr, 10) : 30;

  const model = map.get("model");
  const stripeCustomerStripeId = map.get("stripe_customer_stripe_id");

  return {
    taskRunId,
    encryptedToken,
    task,
    maxSteps: isNaN(maxSteps) ? 30 : maxSteps,
    model: model !== undefined && model !== "" ? model : undefined,
    agentId,
    tenantSubdomain,
    stripeCustomerStripeId: stripeCustomerStripeId !== undefined && stripeCustomerStripeId !== "" ? stripeCustomerStripeId : undefined,
  };
}

export const TaskQueueLive = Layer.effect(
  TaskQueue,
  Effect.gen(function* () {
    const config = yield* Config;
    let redis: IORedis | null = null;

    const getRedis = (): IORedis => {
      if (redis === null) {
        redis = new IORedis(config.redisUrl, {
          maxRetriesPerRequest: 3,
          lazyConnect: true,
        });
      }
      return redis;
    };

    const ensureGroup: TaskQueueService["ensureGroup"] = () =>
      Effect.tryPromise({
        try: async () => {
          const r = getRedis();
          await r.connect().catch(() => { /* already connected */ });
          try {
            await r.xgroup("CREATE", config.streamName, config.consumerGroup, "0", "MKSTREAM");
          } catch (err) {
            // BUSYGROUP = group already exists, that's fine
            const message = err instanceof Error ? err.message : String(err);
            if (!message.includes("BUSYGROUP")) {
              throw err;
            }
          }
        },
        catch: (error) =>
          new RedisError({ message: error instanceof Error ? error.message : String(error) }),
      });

    // Recreate the consumer group if Redis reports it is missing. This happens
    // if the stream or group is deleted out from under us (ops cleanup, a
    // debug `redis.del`, Redis flush). Without this, the runner would spin in
    // a tight NOGROUP error loop indefinitely.
    const readOnce = async (): Promise<StreamEntry | null> => {
      const r = getRedis();
      const results = await r.xreadgroup(
        "GROUP", config.consumerGroup, config.consumerName,
        "COUNT", 1,
        "BLOCK", 5000,
        "STREAMS", config.streamName, ">",
      );

      if (results === null || results.length === 0) return null;
      const stream = results[0] as [string, Array<[string, string[]]>] | undefined;
      if (stream === undefined) return null;
      const entries = stream[1];
      if (entries === undefined || entries.length === 0) return null;
      const entry = entries[0];
      if (entry === undefined) return null;
      const [id, fields] = entry;
      if (id === undefined || fields === undefined) return null;
      const task = parseStreamEntry(fields);
      if (task === null) return null;
      return { id, task } satisfies StreamEntry;
    };

    const read: TaskQueueService["read"] = () =>
      Effect.tryPromise({
        try: async () => {
          try {
            return await readOnce();
          } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            if (message.includes("NOGROUP")) {
              log.warn({ event: "consumer_group_missing_recreating", message });
              const r = getRedis();
              await r.xgroup("CREATE", config.streamName, config.consumerGroup, "0", "MKSTREAM")
                .catch((e: unknown) => {
                  // BUSYGROUP = someone else created it concurrently — fine.
                  const m = e instanceof Error ? e.message : String(e);
                  if (!m.includes("BUSYGROUP")) throw e;
                });
              return await readOnce();
            }
            throw err;
          }
        },
        catch: (error) =>
          new RedisError({ message: error instanceof Error ? error.message : String(error) }),
      });

    const ack: TaskQueueService["ack"] = (entryId) =>
      Effect.tryPromise({
        try: async () => {
          const r = getRedis();
          await r.xack(config.streamName, config.consumerGroup, entryId);
        },
        catch: (error) =>
          new RedisError({ message: error instanceof Error ? error.message : String(error) }),
      });

    // NACK: acknowledge the original message and re-publish it to the stream.
    // This ensures the message appears as a new entry and will be picked up
    // on the next read cycle (when the agent may be free).
    //
    // Known limitation: re-publishing gives the message a new stream ID, which
    // breaks strict FIFO ordering for tasks queued to the same agent. This matches
    // the Ruby implementation's behavior where concurrent Sidekiq workers could
    // also pick up tasks out of order.
    const nack: TaskQueueService["nack"] = (entryId) =>
      Effect.tryPromise({
        try: async () => {
          const r = getRedis();
          // Read the pending message to get its fields
          const entries = await r.xrange(config.streamName, entryId, entryId);
          const entry = entries[0];
          if (entry !== undefined) {
            const [, fields] = entry;
            // Re-publish as a new message
            const fieldPairs: string[] = [];
            for (let i = 0; i < fields.length; i += 2) {
              const k = fields[i];
              const v = fields[i + 1];
              if (k !== undefined && v !== undefined) {
                fieldPairs.push(k, v);
              }
            }
            if (fieldPairs.length > 0) {
              // Re-publish BEFORE acknowledging: if we crash between the two,
              // we get a duplicate (safe — agent lock prevents double-execution)
              // rather than a lost task (unsafe).
              await r.xadd(config.streamName, "MAXLEN", "~", String(config.streamMaxLen), "*", ...fieldPairs);
            }
          }
          // Acknowledge the original after re-publish so it leaves the pending list
          await r.xack(config.streamName, config.consumerGroup, entryId);
        },
        catch: (error) =>
          new RedisError({ message: error instanceof Error ? error.message : String(error) }),
      });

    const publishStats: TaskQueueService["publishStats"] = (stats) =>
      Effect.tryPromise({
        try: async () => {
          const r = getRedis();
          // Write stats as a Redis hash, readable by Rails admin
          await r.set("agent_runner:stats", JSON.stringify(stats), "EX", 60);
        },
        catch: (error) =>
          new RedisError({ message: error instanceof Error ? error.message : String(error) }),
      });

    const streamInfo: TaskQueueService["streamInfo"] = () =>
      Effect.tryPromise({
        try: async () => {
          const r = getRedis();
          const depth = await r.xlen(config.streamName);
          let pending = 0;
          try {
            const info = await r.xpending(config.streamName, config.consumerGroup);
            pending = typeof info[0] === "number" ? info[0] : 0;
          } catch {
            // Stream or group may not exist yet
          }
          return { streamDepth: depth, streamPending: pending };
        },
        catch: (error) =>
          new RedisError({ message: error instanceof Error ? error.message : String(error) }),
      });

    const shutdown: TaskQueueService["shutdown"] = () =>
      Effect.sync(() => {
        if (redis !== null) {
          redis.disconnect();
          redis = null;
        }
      });

    return { read, ack, nack, ensureGroup, publishStats, streamInfo, shutdown };
  }),
);
