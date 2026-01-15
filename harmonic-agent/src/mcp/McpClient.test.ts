import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Effect, Layer } from "effect";
import { McpClient, McpClientLive } from "./McpClient.js";
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
  maxTurns: 20,
  maxTokensPerSession: 100000,
  sessionTimeoutMs: 300000,
};

const ConfigTestLayer = Layer.succeed(ConfigService, mockConfig);
const McpClientTestLayer = Layer.provide(McpClientLive, ConfigTestLayer);

describe("McpClient", () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    vi.resetAllMocks();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe("navigate", () => {
    it("should navigate to a path and return markdown content", async () => {
      const mockMarkdown = "# Test Page\n\nSome content";

      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: true,
        text: () => Promise.resolve(mockMarkdown),
      });

      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const client = yield* McpClient;
          return yield* client.navigate("/studios/test");
        }).pipe(Effect.provide(McpClientTestLayer))
      );

      expect(result.content).toBe(mockMarkdown);
      expect(result.path).toBe("/studios/test");
      expect(globalThis.fetch).toHaveBeenCalledWith(
        "https://test.harmonic.example/studios/test",
        expect.objectContaining({
          method: "GET",
          headers: {
            Accept: "text/markdown",
            Authorization: "Bearer test-token",
          },
        })
      );
    });

    it("should normalize paths without leading slash", async () => {
      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: true,
        text: () => Promise.resolve("content"),
      });

      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const client = yield* McpClient;
          return yield* client.navigate("studios/test");
        }).pipe(Effect.provide(McpClientTestLayer))
      );

      expect(result.path).toBe("/studios/test");
    });

    it("should fail on HTTP error", async () => {
      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: false,
        status: 404,
        text: () => Promise.resolve("Not Found"),
      });

      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const client = yield* McpClient;
          return yield* client.navigate("/not-found");
        }).pipe(Effect.provide(McpClientTestLayer), Effect.either)
      );

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("HTTP 404");
        expect(result.left.statusCode).toBe(404);
      }
    });
  });

  describe("executeAction", () => {
    it("should fail if no navigation has occurred", async () => {
      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const client = yield* McpClient;
          return yield* client.executeAction("test_action");
        }).pipe(Effect.provide(McpClientTestLayer), Effect.either)
      );

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("No current path");
      }
    });

    it("should execute action after navigation", async () => {
      const navResponse = "# Page";
      const actionResponse = "Action completed successfully";

      globalThis.fetch = vi
        .fn()
        .mockResolvedValueOnce({
          ok: true,
          text: () => Promise.resolve(navResponse),
        })
        .mockResolvedValueOnce({
          ok: true,
          text: () => Promise.resolve(actionResponse),
        });

      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const client = yield* McpClient;
          yield* client.navigate("/studios/test/n/abc123");
          return yield* client.executeAction("confirm_read", {});
        }).pipe(Effect.provide(McpClientTestLayer))
      );

      expect(result.content).toBe(actionResponse);
      expect(globalThis.fetch).toHaveBeenNthCalledWith(
        2,
        "https://test.harmonic.example/studios/test/n/abc123/actions/confirm_read",
        expect.objectContaining({
          method: "POST",
          headers: {
            Accept: "text/markdown",
            "Content-Type": "application/json",
            Authorization: "Bearer test-token",
          },
          body: "{}",
        })
      );
    });

    it("should strip /actions suffix from current path", async () => {
      globalThis.fetch = vi
        .fn()
        .mockResolvedValueOnce({
          ok: true,
          text: () => Promise.resolve("nav"),
        })
        .mockResolvedValueOnce({
          ok: true,
          text: () => Promise.resolve("action"),
        });

      await Effect.runPromise(
        Effect.gen(function* () {
          const client = yield* McpClient;
          yield* client.navigate("/studios/test/actions");
          return yield* client.executeAction("some_action");
        }).pipe(Effect.provide(McpClientTestLayer))
      );

      expect(globalThis.fetch).toHaveBeenNthCalledWith(
        2,
        "https://test.harmonic.example/studios/test/actions/some_action",
        expect.anything()
      );
    });
  });

  describe("getCurrentPath", () => {
    it("should return null initially", async () => {
      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const client = yield* McpClient;
          return yield* client.getCurrentPath;
        }).pipe(Effect.provide(McpClientTestLayer))
      );

      expect(result).toBeNull();
    });

    it("should return current path after navigation", async () => {
      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: true,
        text: () => Promise.resolve("content"),
      });

      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const client = yield* McpClient;
          yield* client.navigate("/studios/test");
          return yield* client.getCurrentPath;
        }).pipe(Effect.provide(McpClientTestLayer))
      );

      expect(result).toBe("/studios/test");
    });
  });
});
