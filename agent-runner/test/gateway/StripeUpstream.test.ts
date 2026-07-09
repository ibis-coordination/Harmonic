import { describe, it, expect, afterEach, vi } from "vitest";
import { Effect, Layer } from "effect";
import { StripeUpstream, StripeUpstreamLive } from "../../src/gateway/StripeUpstream.js";
import { Config } from "../../src/config/Config.js";
import type { AppConfig } from "../../src/config/Config.js";

const testConfig: AppConfig = {
  harmonicInternalUrl: "http://web:3000",
  harmonicHostname: "harmonic.local",
  agentRunnerSecret: "test-secret",
  redisUrl: "redis://redis:6379",
  litellmBaseUrl: "http://litellm:4000",
  llmGatewayUrl: "http://llm-gateway:4500",
  stripeGatewayBaseUrl: "https://stripe.test",
  llmGatewayMode: "litellm",
  stripeGatewayKey: "rk_test_gw",
  streamName: "agent_tasks",
  consumerGroup: "agent_runner",
  consumerName: "runner-test",
  maxConcurrentTasks: 100,
  streamMaxLen: 10000,
};

const run = (config: AppConfig, opts: { customerId: string; body: string }) =>
  Effect.runPromise(
    Effect.gen(function* () {
      const stripe = yield* StripeUpstream;
      return yield* Effect.promise(() => stripe.chatCompletions(opts));
    }).pipe(Effect.provide(StripeUpstreamLive.pipe(Layer.provide(Layer.succeed(Config, config))))),
  );

describe("StripeUpstream", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("posts the body verbatim with the gateway key and customer billing header", async () => {
    const fetchSpy = vi.fn(async () => new Response('{"ok":true}', { status: 200 }));
    vi.stubGlobal("fetch", fetchSpy);

    const body = JSON.stringify({ model: "anthropic/claude-sonnet-4.6", messages: [] });
    const result = await run(testConfig, { customerId: "cus_abc", body });

    const [url, init] = fetchSpy.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://stripe.test/chat/completions");
    const headers = init.headers as Record<string, string>;
    expect(headers["Authorization"]).toBe("Bearer rk_test_gw");
    expect(headers["X-Stripe-Customer-ID"]).toBe("cus_abc");
    expect(init.body).toBe(body);
    expect(result).toEqual({ status: 200, body: '{"ok":true}' });
  });

  it("returns the upstream status and body verbatim on error responses", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("insufficient credit", { status: 402 })));

    const result = await run(testConfig, { customerId: "cus_abc", body: "{}" });

    expect(result).toEqual({ status: 402, body: "insufficient credit" });
  });

  it("refuses to call Stripe without the gateway key", async () => {
    const fetchSpy = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", fetchSpy);

    await expect(
      run({ ...testConfig, stripeGatewayKey: undefined }, { customerId: "cus_abc", body: "{}" }),
    ).rejects.toThrow(/STRIPE_GATEWAY_KEY/);
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
