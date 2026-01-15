import { Context, Effect, Layer, Queue } from "effect";
import { QueueError } from "../errors/Errors.js";

export interface WebhookPayload {
  event: string;
  delivery: string;
  timestamp: string;
  body: unknown;
}

export class WebhookQueue extends Context.Tag("WebhookQueue")<
  WebhookQueue,
  {
    readonly enqueue: (payload: WebhookPayload) => Effect.Effect<void, QueueError>;
    readonly take: Effect.Effect<WebhookPayload, QueueError>;
    readonly size: Effect.Effect<number>;
  }
>() {}

export const WebhookQueueLive = Layer.effect(
  WebhookQueue,
  Effect.gen(function* () {
    const queue = yield* Queue.unbounded<WebhookPayload>();

    return {
      enqueue: (payload: WebhookPayload) =>
        Effect.gen(function* () {
          yield* Queue.offer(queue, payload);
        }),

      take: Effect.gen(function* () {
        return yield* Queue.take(queue);
      }),

      size: Queue.size(queue),
    };
  })
);
