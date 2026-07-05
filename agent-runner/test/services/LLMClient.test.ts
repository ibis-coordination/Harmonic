import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { Effect, Layer } from "effect";
import { LLMClient, LLMClientLive } from "../../src/services/LLMClient.js";
import { Config } from "../../src/config/Config.js";
import { log } from "../../src/services/Logger.js";

const baseConfig = {
  harmonicInternalUrl: "http://test:3000",
  harmonicHostname: "test.local",
  agentRunnerSecret: "test-secret",
  redisUrl: "redis://test:6379",
  litellmBaseUrl: "http://litellm:4000",
  stripeGatewayBaseUrl: "https://stripe.test",
  llmGatewayMode: "litellm" as const,
  stripeGatewayKey: undefined,
  streamName: "test_tasks",
  consumerGroup: "test_group",
  consumerName: "test_consumer",
  maxConcurrentTasks: 10,
  streamMaxLen: 1000,
};

const ConfigTest = Layer.succeed(Config, baseConfig);

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function runChat(body: unknown) {
  const fetchSpy = vi.fn(async () => jsonResponse(body));
  vi.stubGlobal("fetch", fetchSpy);
  const program = Effect.gen(function* () {
    const client = yield* LLMClient;
    return yield* client.chat([], undefined, [], undefined);
  });
  return Effect.runPromise(
    program.pipe(Effect.provide(LLMClientLive.pipe(Layer.provide(ConfigTest)))),
  );
}

describe("LLMClient", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("captures reasoning_content from message (DeepSeek / Anthropic via LiteLLM)", async () => {
    const result = await runChat({
      choices: [
        {
          message: {
            content: "Final answer",
            reasoning_content: "Step 1: think. Step 2: act.",
          },
          finish_reason: "stop",
        },
      ],
      usage: { prompt_tokens: 10, completion_tokens: 5 },
    });

    expect(result.reasoning).toBe("Step 1: think. Step 2: act.");
    expect(result.content).toBe("Final answer");
  });

  it("captures reasoning from message (some OpenRouter providers)", async () => {
    const result = await runChat({
      choices: [
        {
          message: {
            content: null,
            reasoning: "Thinking through the problem...",
            tool_calls: [
              {
                id: "call_1",
                type: "function",
                function: { name: "navigate", arguments: '{"path":"/x"}' },
              },
            ],
          },
          finish_reason: "tool_calls",
        },
      ],
    });

    expect(result.reasoning).toBe("Thinking through the problem...");
    expect(result.toolCalls.length).toBe(1);
  });

  it("captures reasoning from choice-level field (OpenAI o-series shape)", async () => {
    const result = await runChat({
      choices: [
        {
          message: { content: "Answer" },
          reasoning: "Chain-of-thought here.",
          finish_reason: "stop",
        },
      ],
    });

    expect(result.reasoning).toBe("Chain-of-thought here.");
  });

  it("returns undefined reasoning when none is provided", async () => {
    const result = await runChat({
      choices: [
        { message: { content: "Plain response" }, finish_reason: "stop" },
      ],
    });

    expect(result.reasoning).toBeUndefined();
  });
});

const okBody = {
  choices: [{ message: { content: "ok" }, finish_reason: "stop" }],
  usage: { prompt_tokens: 1, completion_tokens: 1 },
};

function runChatWith(
  config: Partial<typeof baseConfig>,
  opts: { customerId?: string; gatewayMode?: "litellm" | "stripe_gateway"; response?: Response },
) {
  const fetchSpy = vi.fn(async () => opts.response ?? jsonResponse(okBody));
  vi.stubGlobal("fetch", fetchSpy);
  const layer = Layer.succeed(Config, { ...baseConfig, ...config });
  const program = Effect.gen(function* () {
    const client = yield* LLMClient;
    return yield* client.chat([], undefined, [], opts.customerId, opts.gatewayMode);
  });
  return Effect.runPromise(
    program.pipe(Effect.provide(LLMClientLive.pipe(Layer.provide(layer)))),
  ).then(() => fetchSpy);
}

describe("LLMClient per-task gateway routing", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("routes to the Stripe gateway when the task says stripe_gateway", async () => {
    const fetchSpy = await runChatWith(
      { stripeGatewayKey: "rk_test_123" },
      { customerId: "cus_abc", gatewayMode: "stripe_gateway" },
    );

    const [url, init] = fetchSpy.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://stripe.test/chat/completions");
    const headers = init.headers as Record<string, string>;
    expect(headers["Authorization"]).toBe("Bearer rk_test_123");
    expect(headers["X-Stripe-Customer-ID"]).toBe("cus_abc");
  });

  it("routes to LiteLLM when the task says litellm even if the config default is stripe_gateway", async () => {
    const fetchSpy = await runChatWith(
      { llmGatewayMode: "stripe_gateway", stripeGatewayKey: "rk_test_123" },
      { gatewayMode: "litellm" },
    );

    const [url, init] = fetchSpy.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("http://litellm:4000/v1/chat/completions");
    const headers = init.headers as Record<string, string>;
    expect(headers["Authorization"]).toBeUndefined();
  });

  it("falls back to the config mode when the task carries no mode", async () => {
    const fetchSpy = await runChatWith(
      { llmGatewayMode: "stripe_gateway", stripeGatewayKey: "rk_test_123" },
      { customerId: "cus_abc" },
    );

    const [url] = fetchSpy.mock.calls[0] as unknown as [string];
    expect(url).toBe("https://stripe.test/chat/completions");
  });

  it("fails in stripe_gateway mode without a stripe customer id", async () => {
    await expect(
      runChatWith(
        { stripeGatewayKey: "rk_test_123" },
        { gatewayMode: "stripe_gateway" },
      ),
    ).rejects.toThrow(/customer/i);
  });

  it("fails in stripe_gateway mode without STRIPE_GATEWAY_KEY", async () => {
    await expect(
      runChatWith({}, { customerId: "cus_abc", gatewayMode: "stripe_gateway" }),
    ).rejects.toThrow(/STRIPE_GATEWAY_KEY/);
  });
});

describe("LLMClient request logging", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("logs a structured llm_request line without leaking the customer id", async () => {
    const infoSpy = vi.spyOn(log, "info").mockImplementation(() => {});

    await runChatWith(
      { stripeGatewayKey: "rk_test_123" },
      { customerId: "cus_abc", gatewayMode: "stripe_gateway" },
    );

    const entry = infoSpy.mock.calls
      .map((c) => c[0] as Record<string, unknown>)
      .find((f) => f["event"] === "llm_request");
    expect(entry).toMatchObject({
      event: "llm_request",
      gateway_mode: "stripe_gateway",
      status_code: 200,
      stripe_customer_present: true,
      model: "default",
      input_tokens: 1,
      output_tokens: 1,
    });
    expect(entry?.["duration_ms"]).toBeGreaterThanOrEqual(0);
    expect(JSON.stringify(entry)).not.toContain("cus_abc");
  });

  it("logs the failure status when the gateway rejects the request", async () => {
    const warnSpy = vi.spyOn(log, "warn").mockImplementation(() => {});

    await expect(
      runChatWith(
        { stripeGatewayKey: "rk_test_123" },
        {
          customerId: "cus_abc",
          gatewayMode: "stripe_gateway",
          response: new Response("insufficient credit", { status: 402 }),
        },
      ),
    ).rejects.toThrow(/Payment required/);

    const entry = warnSpy.mock.calls
      .map((c) => c[0] as Record<string, unknown>)
      .find((f) => f["event"] === "llm_request_failed");
    expect(entry).toMatchObject({
      event: "llm_request_failed",
      gateway_mode: "stripe_gateway",
      status_code: 402,
      stripe_customer_present: true,
    });
    expect(JSON.stringify(entry)).not.toContain("cus_abc");
  });
});
