/**
 * Stripe AI Gateway upstream — Effect service.
 *
 * The single outbound hop to `llm.stripe.com`. It attaches the gateway bearer
 * key and the per-call `X-Stripe-Customer-ID` (billing attribution), then
 * returns the upstream response verbatim. Isolated behind a service tag so the
 * relay can be tested without a live Stripe call.
 */

import { Context, Effect, Layer } from "effect";
import { Config } from "../config/Config.js";

export interface StripeUpstreamResult {
  readonly status: number;
  readonly body: string;
}

export interface StripeUpstreamStreamResult {
  readonly status: number;
  readonly contentType: string;
  readonly body: ReadableStream<Uint8Array> | null;
}

export interface StripeUpstreamService {
  readonly chatCompletions: (opts: {
    readonly customerId: string;
    readonly body: string;
  }) => Promise<StripeUpstreamResult>;
  /**
   * Same hop, but the response body is handed back as a stream instead of
   * buffered text — the external ingress pipes it to the client byte for
   * byte, which serves SSE (stream: true) and plain JSON responses alike.
   */
  readonly chatCompletionsStream: (opts: {
    readonly customerId: string;
    readonly body: string;
  }) => Promise<StripeUpstreamStreamResult>;
}

export class StripeUpstream extends Context.Tag("StripeUpstream")<StripeUpstream, StripeUpstreamService>() {}

export const StripeUpstreamLive = Layer.effect(
  StripeUpstream,
  Effect.gen(function* () {
    const config = yield* Config;

    const rawRequest = async ({ customerId, body }: { customerId: string; body: string }): Promise<Response> => {
      if (config.stripeGatewayKey === undefined) {
        throw new Error("STRIPE_GATEWAY_KEY is required to relay to the Stripe AI Gateway");
      }

      return fetch(`${config.stripeGatewayBaseUrl}/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${config.stripeGatewayKey}`,
          "X-Stripe-Customer-ID": customerId,
        },
        body,
        signal: AbortSignal.timeout(120_000),
      });
    };

    const chatCompletions: StripeUpstreamService["chatCompletions"] = async (opts) => {
      const response = await rawRequest(opts);
      const text = await response.text();
      return { status: response.status, body: text };
    };

    const chatCompletionsStream: StripeUpstreamService["chatCompletionsStream"] = async (opts) => {
      const response = await rawRequest(opts);
      return {
        status: response.status,
        contentType: response.headers.get("content-type") ?? "application/json",
        body: response.body,
      };
    };

    return { chatCompletions, chatCompletionsStream };
  }),
);
