import { describe, it, expect, vi } from "vitest";
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

  // Per-path Rails mock: selection succeeds with a selection_id, every other
  // path (record-usage) is captured and returns 200.
  const railsWithLedger = (selectBody: Record<string, unknown>): { layer: Layer.Layer<RailsHttp>; calls: RailsRequestOptions[] } => {
    const calls: RailsRequestOptions[] = [];
    const service: RailsHttpService = {
      request: async (opts): Promise<RailsResponse> => {
        calls.push(opts);
        const body = opts.path === "/internal/llm-gateway/select-payer" ? JSON.stringify(selectBody) : "{}";
        return { statusCode: 200, headers: {}, text: async () => body };
      },
    };
    return { layer: Layer.succeed(RailsHttp, service), calls };
  };

  it("reports usage to record-usage after a completed call", async () => {
    const { layer, calls } = railsWithLedger({ payer_customer_id: "cus_abc", selection_id: "sel_1" });
    const layers = Layer.mergeAll(
      ConfigTest,
      layer,
      stripeLayer(async () => ({
        status: 200,
        body: JSON.stringify({ id: "c1", usage: { prompt_tokens: 11, completion_tokens: 22 } }),
      })),
    );

    const result = await Effect.runPromise(Effect.provide(relay(req), layers));
    expect(result.status).toBe(200);

    await vi.waitFor(() => {
      expect(calls.some((c) => c.path === "/internal/llm-gateway/record-usage")).toBe(true);
    });
    const report = calls.find((c) => c.path === "/internal/llm-gateway/record-usage");
    expect(report?.subdomain).toBe("acme");
    expect(report?.headers?.["X-Internal-Signature"]).toBeTruthy();
    expect(JSON.parse(report?.body ?? "{}")).toEqual({
      selection_id: "sel_1",
      model: "anthropic/claude-sonnet-4.6",
      input_tokens: 11,
      output_tokens: 22,
      status: "ok",
    });
  });

  it("reports an upstream error so the ledger row is closed as failed", async () => {
    const { layer, calls } = railsWithLedger({ payer_customer_id: "cus_abc", selection_id: "sel_err" });
    const layers = Layer.mergeAll(
      ConfigTest,
      layer,
      stripeLayer(async () => ({ status: 400, body: JSON.stringify({ error: { message: "no balance" } }) })),
    );

    await Effect.runPromise(Effect.provide(relay(req), layers));

    await vi.waitFor(() => {
      expect(calls.some((c) => c.path === "/internal/llm-gateway/record-usage")).toBe(true);
    });
    const report = calls.find((c) => c.path === "/internal/llm-gateway/record-usage");
    expect(JSON.parse(report?.body ?? "{}")).toMatchObject({ selection_id: "sel_err", status: "error" });
  });

  it("skips record-usage when select-payer returned no selection id", async () => {
    const { layer, calls } = railsWithLedger({ payer_customer_id: "cus_abc" });
    const layers = Layer.mergeAll(
      ConfigTest,
      layer,
      stripeLayer(async () => ({ status: 200, body: JSON.stringify({ id: "c1", usage: { prompt_tokens: 1, completion_tokens: 1 } }) })),
    );

    await Effect.runPromise(Effect.provide(relay(req), layers));
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(calls.every((c) => c.path !== "/internal/llm-gateway/record-usage")).toBe(true);
  });
});
