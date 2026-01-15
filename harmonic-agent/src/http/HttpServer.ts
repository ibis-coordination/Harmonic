import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { Context, Effect, Layer } from "effect";
import { ConfigService } from "../config/Config.js";
import { WebhookQueue, type WebhookPayload } from "../queue/WebhookQueue.js";
import {
  extractWebhookHeaders,
  verifyWebhookSignature,
} from "./WebhookVerification.js";

export class HttpServer extends Context.Tag("HttpServer")<
  HttpServer,
  {
    readonly start: Effect.Effect<void>;
    readonly stop: Effect.Effect<void>;
  }
>() {}

export const HttpServerLive = Layer.effect(
  HttpServer,
  Effect.gen(function* () {
    const config = yield* ConfigService;
    const webhookQueue = yield* WebhookQueue;

    const app = new Hono();

    // Health check endpoint
    app.get("/health", (c) => c.json({ status: "ok" }));

    // Webhook endpoint
    app.post("/webhook", async (c) => {
      const body = await c.req.text();

      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const headers = yield* extractWebhookHeaders(c.req.raw.headers);

          yield* verifyWebhookSignature(
            body,
            headers.timestamp,
            headers.signature,
            config.webhookSecret
          );

          let parsedBody: unknown;
          try {
            parsedBody = JSON.parse(body);
          } catch {
            parsedBody = body;
          }

          const payload: WebhookPayload = {
            event: headers.event,
            delivery: headers.delivery,
            timestamp: headers.timestamp,
            body: parsedBody,
          };

          yield* webhookQueue.enqueue(payload);

          return { success: true, delivery: headers.delivery };
        }).pipe(
          Effect.catchAll((error) =>
            Effect.succeed({ error: error.message, success: false })
          )
        )
      );

      if ("error" in result) {
        return c.json(result, 400);
      }

      return c.json(result, 200);
    });

    let server: ReturnType<typeof serve> | null = null;

    return {
      start: Effect.sync(() => {
        server = serve({
          fetch: app.fetch,
          port: config.port,
          hostname: config.host,
        });
        console.log(`Server started on ${config.host}:${config.port}`);
      }),

      stop: Effect.sync(() => {
        if (server) {
          server.close();
          console.log("Server stopped");
        }
      }),
    };
  })
);
