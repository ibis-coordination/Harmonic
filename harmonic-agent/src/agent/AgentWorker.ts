import { Context, Effect, Layer, Fiber } from "effect";
import { WebhookQueue, type WebhookPayload } from "../queue/WebhookQueue.js";
import { AgentLoop } from "./AgentLoop.js";

export class AgentWorker extends Context.Tag("AgentWorker")<
  AgentWorker,
  {
    readonly start: Effect.Effect<void>;
    readonly stop: Effect.Effect<void>;
  }
>() {}

export const AgentWorkerLive = Layer.effect(
  AgentWorker,
  Effect.gen(function* () {
    const webhookQueue = yield* WebhookQueue;
    const agentLoop = yield* AgentLoop;

    let workerFiber: Fiber.RuntimeFiber<void, unknown> | null = null;
    let running = true;

    const processWebhooks = Effect.gen(function* () {
      while (running) {
        const payload: WebhookPayload = yield* webhookQueue.take;

        console.log(`[Worker] Processing webhook: ${payload.event} (${payload.delivery})`);

        // Run agent session for this webhook
        const sessionId = `${payload.event}-${payload.delivery.slice(0, 8)}`;

        yield* Effect.catchAll(
          agentLoop.runSession(sessionId),
          (error) => {
            console.error(`[Worker] Agent session failed: ${error.message}`);
            return Effect.void;
          }
        );
      }
    });

    return {
      start: Effect.gen(function* () {
        running = true;
        workerFiber = yield* Effect.fork(processWebhooks);
        console.log("[Worker] Started webhook processing");
      }),

      stop: Effect.gen(function* () {
        running = false;
        if (workerFiber) {
          yield* Fiber.interrupt(workerFiber);
          console.log("[Worker] Stopped webhook processing");
        }
      }),
    };
  })
);
