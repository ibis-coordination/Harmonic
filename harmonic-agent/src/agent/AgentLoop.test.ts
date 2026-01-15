import { describe, it, expect, vi } from "vitest";
import { Effect, Layer } from "effect";
import { AgentLoop, AgentLoopLive } from "./AgentLoop.js";
import { McpClient } from "../mcp/McpClient.js";
import { AiProvider, type AiResponse } from "../ai/AiProvider.js";
import { ConfigService, type Config } from "../config/Config.js";

const mockConfig: Config = {
  port: 3001,
  host: "0.0.0.0",
  harmonicBaseUrl: "https://test.harmonic.example",
  harmonicApiToken: "test-token",
  webhookSecret: "test-secret",
  aiProvider: "claude",
  anthropicApiKey: "test-anthropic-key",
  openaiApiKey: undefined,
  aiModel: "claude-sonnet-4-20250514",
  maxTurns: 5,
  maxTokensPerSession: 100000,
  sessionTimeoutMs: 300000,
};

describe("AgentLoop", () => {
  it("should run a session that ends after AI returns end_turn", async () => {
    const navigateMock = vi.fn().mockReturnValue(
      Effect.succeed({ content: "# Notifications\n\nNo new notifications", path: "/notifications" })
    );

    const McpClientTest = Layer.succeed(McpClient, {
      navigate: navigateMock,
      executeAction: vi.fn(),
      getCurrentPath: Effect.succeed("/notifications"),
    });

    const aiChatMock = vi.fn().mockReturnValue(
      Effect.succeed({
        content: [{ type: "text", text: "No action needed." }],
        stopReason: "end_turn",
        usage: { inputTokens: 100, outputTokens: 20 },
      } satisfies AiResponse)
    );

    const AiProviderTest = Layer.succeed(AiProvider, {
      chat: aiChatMock,
    });

    const ConfigTest = Layer.succeed(ConfigService, mockConfig);

    const testLayer = AgentLoopLive.pipe(
      Layer.provide(McpClientTest),
      Layer.provide(AiProviderTest),
      Layer.provide(ConfigTest)
    );

    const result = await Effect.runPromise(
      Effect.gen(function* () {
        const agentLoop = yield* AgentLoop;
        return yield* agentLoop.runSession("test-session");
      }).pipe(Effect.provide(testLayer))
    );

    expect(result.sessionId).toBe("test-session");
    expect(result.turns).toBe(1);
    expect(result.totalInputTokens).toBe(100);
    expect(result.totalOutputTokens).toBe(20);
    expect(navigateMock).toHaveBeenCalledWith("/notifications");
    expect(aiChatMock).toHaveBeenCalledTimes(1);
  });

  it("should execute tool calls and continue looping", async () => {
    const navigateMock = vi.fn()
      .mockReturnValueOnce(
        Effect.succeed({ content: "# Notifications\n\n- New note", path: "/notifications" })
      )
      .mockReturnValueOnce(
        Effect.succeed({ content: "# Note Content", path: "/studios/test/n/abc123" })
      );

    const executeActionMock = vi.fn().mockReturnValue(
      Effect.succeed({ content: "Read confirmed" })
    );

    const McpClientTest = Layer.succeed(McpClient, {
      navigate: navigateMock,
      executeAction: executeActionMock,
      getCurrentPath: Effect.succeed("/studios/test/n/abc123"),
    });

    let chatCallCount = 0;
    const aiChatMock = vi.fn().mockImplementation(() => {
      chatCallCount++;
      if (chatCallCount === 1) {
        // First call: navigate to the note
        return Effect.succeed({
          content: [
            { type: "text", text: "Let me check that note." },
            {
              type: "tool_use",
              id: "tool-1",
              name: "navigate",
              input: { path: "/studios/test/n/abc123" },
            },
          ],
          stopReason: "tool_use",
          usage: { inputTokens: 100, outputTokens: 30 },
        } satisfies AiResponse);
      } else if (chatCallCount === 2) {
        // Second call: confirm read
        return Effect.succeed({
          content: [
            { type: "text", text: "I'll confirm I read this." },
            {
              type: "tool_use",
              id: "tool-2",
              name: "execute_action",
              input: { action: "confirm_read", params: {} },
            },
          ],
          stopReason: "tool_use",
          usage: { inputTokens: 200, outputTokens: 40 },
        } satisfies AiResponse);
      } else {
        // Third call: done
        return Effect.succeed({
          content: [{ type: "text", text: "All done!" }],
          stopReason: "end_turn",
          usage: { inputTokens: 300, outputTokens: 20 },
        } satisfies AiResponse);
      }
    });

    const AiProviderTest = Layer.succeed(AiProvider, {
      chat: aiChatMock,
    });

    const ConfigTest = Layer.succeed(ConfigService, mockConfig);

    const testLayer = AgentLoopLive.pipe(
      Layer.provide(McpClientTest),
      Layer.provide(AiProviderTest),
      Layer.provide(ConfigTest)
    );

    const result = await Effect.runPromise(
      Effect.gen(function* () {
        const agentLoop = yield* AgentLoop;
        return yield* agentLoop.runSession("test-session");
      }).pipe(Effect.provide(testLayer))
    );

    expect(result.turns).toBe(3);
    expect(result.totalInputTokens).toBe(600); // 100 + 200 + 300
    expect(result.totalOutputTokens).toBe(90); // 30 + 40 + 20
    expect(navigateMock).toHaveBeenCalledTimes(2);
    expect(executeActionMock).toHaveBeenCalledWith("confirm_read", {});
  });

  it("should stop at max turns limit", async () => {
    const navigateMock = vi.fn().mockReturnValue(
      Effect.succeed({ content: "# Page", path: "/notifications" })
    );

    const McpClientTest = Layer.succeed(McpClient, {
      navigate: navigateMock,
      executeAction: vi.fn().mockReturnValue(Effect.succeed({ content: "ok" })),
      getCurrentPath: Effect.succeed("/notifications"),
    });

    // AI always wants to do more
    const aiChatMock = vi.fn().mockReturnValue(
      Effect.succeed({
        content: [
          {
            type: "tool_use",
            id: "tool-1",
            name: "navigate",
            input: { path: "/somewhere" },
          },
        ],
        stopReason: "tool_use",
        usage: { inputTokens: 100, outputTokens: 20 },
      } satisfies AiResponse)
    );

    const AiProviderTest = Layer.succeed(AiProvider, {
      chat: aiChatMock,
    });

    const ConfigTest = Layer.succeed(ConfigService, { ...mockConfig, maxTurns: 3 });

    const testLayer = AgentLoopLive.pipe(
      Layer.provide(McpClientTest),
      Layer.provide(AiProviderTest),
      Layer.provide(ConfigTest)
    );

    const result = await Effect.runPromise(
      Effect.gen(function* () {
        const agentLoop = yield* AgentLoop;
        return yield* agentLoop.runSession("test-session");
      }).pipe(Effect.provide(testLayer))
    );

    expect(result.turns).toBe(3); // Hit max turns
    expect(aiChatMock).toHaveBeenCalledTimes(3);
  });

  it("should handle tool execution errors gracefully", async () => {
    const navigateMock = vi.fn()
      .mockReturnValueOnce(
        Effect.succeed({ content: "# Notifications", path: "/notifications" })
      )
      .mockReturnValueOnce(
        Effect.fail({ message: "Not found", _tag: "McpClientError" })
      );

    const McpClientTest = Layer.succeed(McpClient, {
      navigate: navigateMock,
      executeAction: vi.fn(),
      getCurrentPath: Effect.succeed("/notifications"),
    });

    let callCount = 0;
    const aiChatMock = vi.fn().mockImplementation(() => {
      callCount++;
      if (callCount === 1) {
        return Effect.succeed({
          content: [
            {
              type: "tool_use",
              id: "tool-1",
              name: "navigate",
              input: { path: "/bad-path" },
            },
          ],
          stopReason: "tool_use",
          usage: { inputTokens: 100, outputTokens: 20 },
        } satisfies AiResponse);
      }
      return Effect.succeed({
        content: [{ type: "text", text: "Got an error, stopping." }],
        stopReason: "end_turn",
        usage: { inputTokens: 150, outputTokens: 25 },
      } satisfies AiResponse);
    });

    const AiProviderTest = Layer.succeed(AiProvider, {
      chat: aiChatMock,
    });

    const ConfigTest = Layer.succeed(ConfigService, mockConfig);

    const testLayer = AgentLoopLive.pipe(
      Layer.provide(McpClientTest),
      Layer.provide(AiProviderTest),
      Layer.provide(ConfigTest)
    );

    const result = await Effect.runPromise(
      Effect.gen(function* () {
        const agentLoop = yield* AgentLoop;
        return yield* agentLoop.runSession("test-session");
      }).pipe(Effect.provide(testLayer))
    );

    // Should continue and handle error gracefully
    expect(result.turns).toBe(2);
  });
});
