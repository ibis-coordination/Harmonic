import { describe, it, expect } from "vitest";
import { Effect, Layer, Exit } from "effect";
import { HarmonicClient, HarmonicClientLive, type ChatHistoryResponse } from "../../src/services/HarmonicClient.js";
import { RailsHttp, type RailsRequestOptions, type RailsResponse } from "../../src/services/RailsHttp.js";
import { Config } from "../../src/config/Config.js";
import type { HarmonicApiError } from "../../src/errors/Errors.js";

const TEST_CONFIG = {
  harmonicInternalUrl: "http://web:3000",
  harmonicHostname: "harmonic.local",
  agentRunnerSecret: "test-secret",
  redisUrl: "redis://localhost:6379",
  llmBaseUrl: "http://localhost:4000",
  llmGatewayMode: "litellm" as const,
  stripeGatewayKey: undefined,
  streamName: "agent_tasks",
  consumerGroup: "agent_runners",
  consumerName: "test",
  maxConcurrentTasks: 1,
  streamMaxLen: 1000,
};

function makeResponse(statusCode: number, body: string): RailsResponse {
  return { statusCode, headers: {}, text: async () => body };
}

function runFetchChatHistory(handler: (opts: RailsRequestOptions) => RailsResponse): Promise<Exit.Exit<ChatHistoryResponse, HarmonicApiError>> {
  const RailsHttpTest = Layer.succeed(RailsHttp, {
    request: async (opts: RailsRequestOptions) => handler(opts),
  });
  const ConfigTest = Layer.succeed(Config, TEST_CONFIG);
  const layer = HarmonicClientLive.pipe(Layer.provide(Layer.merge(RailsHttpTest, ConfigTest)));

  const program = Effect.gen(function* () {
    const client = yield* HarmonicClient;
    return yield* client.fetchChatHistory("session-abc", "app");
  });
  return Effect.runPromiseExit(program.pipe(Effect.provide(layer)));
}

describe("HarmonicClient.fetchChatHistory", () => {
  it("hits the HMAC /internal chat-history path with the chat session id", async () => {
    let observedOpts: RailsRequestOptions | undefined;
    const handler = (opts: RailsRequestOptions) => {
      observedOpts = opts;
      return makeResponse(200, JSON.stringify({ messages: [], current_state: {} }));
    };
    const exit = await runFetchChatHistory(handler);

    expect(Exit.isSuccess(exit)).toBe(true);
    expect(observedOpts?.method).toBe("GET");
    expect(observedOpts?.path).toBe("/internal/agent-runner/chat/session-abc/history");
    expect(observedOpts?.subdomain).toBe("app");
    // HMAC headers from buildHeaders: X-Internal-Signature + X-Internal-Timestamp
    expect(observedOpts?.headers?.["X-Internal-Signature"]).toBeDefined();
    expect(observedOpts?.headers?.["X-Internal-Timestamp"]).toBeDefined();
  });

  it("parses the response into messages + current_state", async () => {
    const body = JSON.stringify({
      messages: [
        { content: "hi", role: "user", timestamp: "2026-06-15T10:00:00Z" },
        { content: "hello back", role: "assistant", timestamp: "2026-06-15T10:00:01Z" },
      ],
      current_state: { current_path: "/collectives/foo" },
    });
    const exit = await runFetchChatHistory(() => makeResponse(200, body));

    expect(Exit.isSuccess(exit)).toBe(true);
    if (Exit.isSuccess(exit)) {
      expect(exit.value.messages).toHaveLength(2);
      expect(exit.value.messages[0]?.role).toBe("user");
      expect(exit.value.current_state.current_path).toBe("/collectives/foo");
    }
  });

  it("surfaces non-2xx HTTP responses as HarmonicApiError", async () => {
    const exit = await runFetchChatHistory(() => makeResponse(500, "Internal Server Error"));
    expect(Exit.isFailure(exit)).toBe(true);
    if (Exit.isFailure(exit)) {
      const dump = JSON.stringify(exit.cause);
      expect(dump).toMatch(/HTTP 500/);
    }
  });

  it("surfaces malformed JSON as HarmonicApiError", async () => {
    const exit = await runFetchChatHistory(() => makeResponse(200, "not json at all"));
    expect(Exit.isFailure(exit)).toBe(true);
  });
});
