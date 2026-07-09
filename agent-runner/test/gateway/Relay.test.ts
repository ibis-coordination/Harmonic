import { describe, it, expect } from "vitest";
import { Effect, Layer } from "effect";
import { relay } from "../../src/gateway/Relay.js";
import { StripeUpstream } from "../../src/gateway/StripeUpstream.js";
import type { StripeUpstreamService } from "../../src/gateway/StripeUpstream.js";
import { RailsHttp } from "../../src/services/RailsHttp.js";
import type { RailsHttpService, RailsResponse, RailsRequestOptions } from "../../src/services/RailsHttp.js";
import { Config } from "../../src/config/Config.js";
import type { AppConfig } from "../../src/config/Config.js";

const testConfig: AppConfig = {
  harmonicInternalUrl: "http://web:3000",
  harmonicHostname: "harmonic.local",
  agentRunnerSecret: "test-secret",
  redisUrl: "redis://redis:6379",
  litellmBaseUrl: "http://litellm:4000",
  llmGatewayUrl: "http://llm-gateway:4500",
  stripeGatewayBaseUrl: "https://llm.stripe.com",
  llmGatewayMode: "stripe_gateway",
  stripeGatewayKey: "sk_test",
  streamName: "agent_tasks",
  consumerGroup: "agent_runner",
  consumerName: "runner-test",
  maxConcurrentTasks: 100,
  streamMaxLen: 10000,
};
const ConfigTest = Layer.succeed(Config, testConfig);

// Mock RailsHttp: canned select-payer response; optionally capture the request.
const railsLayer = (
  resp: { statusCode: number; body: string },
  capture?: (opts: RailsRequestOptions) => void,
): Layer.Layer<RailsHttp> => {
  const service: RailsHttpService = {
    request: async (opts): Promise<RailsResponse> => {
      capture?.(opts);
      return { statusCode: resp.statusCode, headers: {}, text: async () => resp.body };
    },
  };
  return Layer.succeed(RailsHttp, service);
};

// Mock StripeUpstream with a supplied implementation.
const stripeLayer = (impl: StripeUpstreamService["chatCompletions"]): Layer.Layer<StripeUpstream> =>
  Layer.succeed(StripeUpstream, { chatCompletions: impl });

const req = {
  taskRunId: "task-run-1",
  subdomain: "acme",
  model: "anthropic/claude-sonnet-4.6",
  body: JSON.stringify({ model: "anthropic/claude-sonnet-4.6", messages: [] }),
};

describe("gateway relay", () => {
  it("resolves the payer and forwards to Stripe with the customer header", async () => {
    let capturedCustomerId: string | undefined;
    let capturedSelectPath: string | undefined;
    let capturedSubdomain: string | undefined;

    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer(
        { statusCode: 200, body: JSON.stringify({ payer_customer_id: "cus_abc" }) },
        (opts) => {
          capturedSelectPath = opts.path;
          capturedSubdomain = opts.subdomain;
        },
      ),
      stripeLayer(async ({ customerId, body }) => {
        capturedCustomerId = customerId;
        return { status: 200, body: `{"echoed":${JSON.stringify(body)}}` };
      }),
    );

    const result = await Effect.runPromise(Effect.provide(relay(req), layers));

    expect(result.status).toBe(200);
    expect(capturedCustomerId).toBe("cus_abc");
    expect(capturedSelectPath).toBe("/internal/llm-gateway/select-payer");
    expect(capturedSubdomain).toBe("acme");
  });

  it("bounds the select-payer hop with a short timeout so the relay budget stays under the caller's", async () => {
    let capturedTimeout: number | undefined;

    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer(
        { statusCode: 200, body: JSON.stringify({ payer_customer_id: "cus_abc" }) },
        (opts) => {
          capturedTimeout = opts.timeoutMs;
        },
      ),
      stripeLayer(async () => ({ status: 200, body: "{}" })),
    );

    await Effect.runPromise(Effect.provide(relay(req), layers));

    expect(capturedTimeout).toBe(10_000);
  });

  it("propagates a select-payer failure without calling Stripe", async () => {
    let stripeCalled = false;

    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer({ statusCode: 402, body: JSON.stringify({ error: "not_funded" }) }),
      stripeLayer(async () => {
        stripeCalled = true;
        return { status: 200, body: "{}" };
      }),
    );

    const result = await Effect.runPromise(Effect.provide(relay(req), layers));

    expect(result.status).toBe(402);
    expect(JSON.parse(result.body)).toEqual({ error: "not_funded" });
    expect(stripeCalled).toBe(false);
  });

  it("propagates a Stripe error status back to the caller", async () => {
    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer({ statusCode: 200, body: JSON.stringify({ payer_customer_id: "cus_abc" }) }),
      stripeLayer(async () => ({ status: 402, body: JSON.stringify({ error: "payment required" }) })),
    );

    const result = await Effect.runPromise(Effect.provide(relay(req), layers));

    expect(result.status).toBe(402);
  });
});
