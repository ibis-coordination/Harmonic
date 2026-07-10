import { describe, it, expect } from "vitest";
import { Effect, Layer } from "effect";
import { externalRelay } from "../../src/gateway/ExternalRelay.js";
import { StripeUpstream } from "../../src/gateway/StripeUpstream.js";
import type { StripeUpstreamService } from "../../src/gateway/StripeUpstream.js";
import { RailsHttp } from "../../src/services/RailsHttp.js";
import type { RailsHttpService, RailsResponse, RailsRequestOptions } from "../../src/services/RailsHttp.js";
import { Config } from "../../src/config/Config.js";
import type { AppConfig } from "../../src/config/Config.js";

const testConfig: AppConfig = {
  harmonicInternalUrl: "http://web:3000",
  harmonicHostname: "harmonic.local",
  primarySubdomain: "app",
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

const streamOf = (text: string): ReadableStream<Uint8Array> => new Response(text).body!;

// Mock StripeUpstream: external relay uses only the streaming variant.
const stripeLayer = (
  impl: StripeUpstreamService["chatCompletionsStream"],
): Layer.Layer<StripeUpstream> =>
  Layer.succeed(StripeUpstream, {
    chatCompletions: async () => {
      throw new Error("external relay must use the streaming variant");
    },
    chatCompletionsStream: impl,
  });

const req = {
  bearerToken: "hg_agent_key_123",
  body: JSON.stringify({ model: "default", stream: true, messages: [{ role: "user", content: "hi" }] }),
};

describe("external relay", () => {
  it("authenticates via select-payer-for-token and forwards with the mapped model", async () => {
    let capturedOpts: RailsRequestOptions | undefined;
    let capturedCustomerId: string | undefined;
    let capturedBody: string | undefined;

    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer(
        {
          statusCode: 200,
          body: JSON.stringify({ payer_customer_id: "cus_abc", model: "anthropic/claude-sonnet-4.6" }),
        },
        (opts) => {
          capturedOpts = opts;
        },
      ),
      stripeLayer(async ({ customerId, body }) => {
        capturedCustomerId = customerId;
        capturedBody = body;
        return { status: 200, contentType: "text/event-stream", body: streamOf("data: ok\n\n") };
      }),
    );

    const result = await Effect.runPromise(Effect.provide(externalRelay(req), layers));

    expect(capturedOpts?.path).toBe("/internal/llm-gateway/select-payer-for-token");
    expect(capturedOpts?.subdomain).toBe("app");
    expect(capturedOpts?.timeoutMs).toBe(10_000);
    expect(JSON.parse(capturedOpts?.body ?? "{}")).toEqual({
      agent_token: "hg_agent_key_123",
      model: "default",
    });

    expect(capturedCustomerId).toBe("cus_abc");
    // The forwarded body is the client's body with the model rewritten.
    expect(JSON.parse(capturedBody ?? "{}")).toEqual({
      model: "anthropic/claude-sonnet-4.6",
      stream: true,
      messages: [{ role: "user", content: "hi" }],
    });

    expect(result.status).toBe(200);
    expect(result.contentType).toBe("text/event-stream");
    expect(await new Response(result.body as ReadableStream<Uint8Array>).text()).toBe("data: ok\n\n");
  });

  it("passes a select-payer rejection through verbatim without calling Stripe", async () => {
    let stripeCalled = false;
    const errorBody = JSON.stringify({
      error: { message: "LLM gateway access is not enabled for this account.", type: "invalid_request_error", code: "feature_disabled" },
    });

    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer({ statusCode: 403, body: errorBody }),
      stripeLayer(async () => {
        stripeCalled = true;
        return { status: 200, contentType: "application/json", body: streamOf("{}") };
      }),
    );

    const result = await Effect.runPromise(Effect.provide(externalRelay(req), layers));

    expect(result.status).toBe(403);
    expect(result.contentType).toBe("application/json");
    expect(result.body).toBe(errorBody);
    expect(stripeCalled).toBe(false);
  });

  it("rejects an unparseable body without calling Rails or Stripe", async () => {
    let railsCalled = false;
    let stripeCalled = false;

    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer({ statusCode: 200, body: "{}" }, () => {
        railsCalled = true;
      }),
      stripeLayer(async () => {
        stripeCalled = true;
        return { status: 200, contentType: "application/json", body: streamOf("{}") };
      }),
    );

    const result = await Effect.runPromise(
      Effect.provide(externalRelay({ bearerToken: "hg_key", body: "not json{" }), layers),
    );

    expect(result.status).toBe(400);
    const parsed = JSON.parse(result.body as string);
    expect(parsed.error.code).toBe("invalid_json");
    expect(parsed.error.type).toBe("invalid_request_error");
    expect(railsCalled).toBe(false);
    expect(stripeCalled).toBe(false);
  });

  it("fails when select-payer succeeds without a payer_customer_id", async () => {
    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer({ statusCode: 200, body: JSON.stringify({ model: "anthropic/claude-sonnet-4.6" }) }),
      stripeLayer(async () => ({ status: 200, contentType: "application/json", body: streamOf("{}") })),
    );

    await expect(Effect.runPromise(Effect.provide(externalRelay(req), layers))).rejects.toThrow(
      /payer_customer_id/,
    );
  });

  it("omits a missing model from the select-payer request rather than sending undefined", async () => {
    let capturedBody: string | undefined;

    const layers = Layer.mergeAll(
      ConfigTest,
      railsLayer(
        { statusCode: 200, body: JSON.stringify({ payer_customer_id: "cus_abc", model: "anthropic/claude-sonnet-4.6" }) },
        (opts) => {
          capturedBody = opts.body;
        },
      ),
      stripeLayer(async () => ({ status: 200, contentType: "application/json", body: streamOf("{}") })),
    );

    await Effect.runPromise(
      Effect.provide(externalRelay({ bearerToken: "hg_key", body: JSON.stringify({ messages: [] }) }), layers),
    );

    expect(JSON.parse(capturedBody ?? "{}")).toEqual({ agent_token: "hg_key" });
  });
});
