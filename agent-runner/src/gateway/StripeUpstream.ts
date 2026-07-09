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

export interface StripeUpstreamService {
  readonly chatCompletions: (opts: {
    readonly customerId: string;
    readonly body: string;
  }) => Promise<StripeUpstreamResult>;
}

export class StripeUpstream extends Context.Tag("StripeUpstream")<StripeUpstream, StripeUpstreamService>() {}

export const StripeUpstreamLive = Layer.effect(
  StripeUpstream,
  Effect.gen(function* () {
    const config = yield* Config;

    const chatCompletions: StripeUpstreamService["chatCompletions"] = async ({ customerId, body }) => {
      if (config.stripeGatewayKey === undefined) {
        throw new Error("STRIPE_GATEWAY_KEY is required to relay to the Stripe AI Gateway");
      }

      const response = await fetch(`${config.stripeGatewayBaseUrl}/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${config.stripeGatewayKey}`,
          "X-Stripe-Customer-ID": customerId,
        },
        body,
        signal: AbortSignal.timeout(120_000),
      });

      const text = await response.text();
      return { status: response.status, body: text };
    };

    return { chatCompletions };
  }),
);
