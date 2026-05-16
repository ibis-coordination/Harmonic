import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { Effect, Layer } from "effect";
import { LLMClient, LLMClientLive } from "../../src/services/LLMClient.js";
import { Config } from "../../src/config/Config.js";

const ConfigTest = Layer.succeed(Config, {
  harmonicInternalUrl: "http://test:3000",
  harmonicHostname: "test.local",
  agentRunnerSecret: "test-secret",
  redisUrl: "redis://test:6379",
  llmBaseUrl: "http://litellm:4000",
  llmGatewayMode: "litellm" as const,
  stripeGatewayKey: undefined,
  streamName: "test_tasks",
  consumerGroup: "test_group",
  consumerName: "test_consumer",
  maxConcurrentTasks: 10,
  streamMaxLen: 1000,
});

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
