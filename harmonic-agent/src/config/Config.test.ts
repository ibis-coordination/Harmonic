import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { Effect } from "effect";
import { loadConfig } from "./Config.js";

describe("Config", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  describe("loadConfig", () => {
    const validEnv = {
      HARMONIC_BASE_URL: "https://test.harmonic.example",
      HARMONIC_API_TOKEN: "test-token",
      WEBHOOK_SECRET: "test-secret",
      ANTHROPIC_API_KEY: "test-anthropic-key",
    };

    it("should load config with valid environment variables", async () => {
      Object.assign(process.env, validEnv);

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Right");
      if (result._tag === "Right") {
        expect(result.right.port).toBe(3001); // default
        expect(result.right.host).toBe("0.0.0.0"); // default
        expect(result.right.harmonicBaseUrl).toBe("https://test.harmonic.example");
        expect(result.right.harmonicApiToken).toBe("test-token");
        expect(result.right.webhookSecret).toBe("test-secret");
        expect(result.right.aiProvider).toBe("claude"); // default
        expect(result.right.aiModel).toBe("claude-sonnet-4-20250514"); // default
        expect(result.right.maxTurns).toBe(20); // default
      }
    });

    it("should use custom port when provided", async () => {
      Object.assign(process.env, validEnv, { PORT: "8080" });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Right");
      if (result._tag === "Right") {
        expect(result.right.port).toBe(8080);
      }
    });

    it("should fail when HARMONIC_BASE_URL is missing", async () => {
      Object.assign(process.env, {
        HARMONIC_API_TOKEN: "test-token",
        WEBHOOK_SECRET: "test-secret",
        ANTHROPIC_API_KEY: "test-key",
      });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("HARMONIC_BASE_URL");
      }
    });

    it("should fail when HARMONIC_API_TOKEN is missing", async () => {
      Object.assign(process.env, {
        HARMONIC_BASE_URL: "https://test.example",
        WEBHOOK_SECRET: "test-secret",
        ANTHROPIC_API_KEY: "test-key",
      });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("HARMONIC_API_TOKEN");
      }
    });

    it("should fail when claude provider is selected but ANTHROPIC_API_KEY is missing", async () => {
      Object.assign(process.env, {
        HARMONIC_BASE_URL: "https://test.example",
        HARMONIC_API_TOKEN: "test-token",
        WEBHOOK_SECRET: "test-secret",
        AI_PROVIDER: "claude",
        // ANTHROPIC_API_KEY intentionally missing
      });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("ANTHROPIC_API_KEY");
        expect(result.left.field).toBe("anthropicApiKey");
      }
    });

    it("should fail when openai provider is selected but OPENAI_API_KEY is missing", async () => {
      Object.assign(process.env, {
        HARMONIC_BASE_URL: "https://test.example",
        HARMONIC_API_TOKEN: "test-token",
        WEBHOOK_SECRET: "test-secret",
        AI_PROVIDER: "openai",
        // OPENAI_API_KEY intentionally missing
      });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("OPENAI_API_KEY");
        expect(result.left.field).toBe("openaiApiKey");
      }
    });

    it("should accept openai provider with OPENAI_API_KEY", async () => {
      Object.assign(process.env, {
        HARMONIC_BASE_URL: "https://test.example",
        HARMONIC_API_TOKEN: "test-token",
        WEBHOOK_SECRET: "test-secret",
        AI_PROVIDER: "openai",
        OPENAI_API_KEY: "test-openai-key",
      });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Right");
      if (result._tag === "Right") {
        expect(result.right.aiProvider).toBe("openai");
        expect(result.right.openaiApiKey).toBe("test-openai-key");
      }
    });

    it("should fail with invalid URL", async () => {
      Object.assign(process.env, {
        HARMONIC_BASE_URL: "not-a-url",
        HARMONIC_API_TOKEN: "test-token",
        WEBHOOK_SECRET: "test-secret",
        ANTHROPIC_API_KEY: "test-key",
      });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("validation failed");
      }
    });

    it("should fail with invalid port", async () => {
      Object.assign(process.env, validEnv, { PORT: "not-a-number" });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Left");
    });

    it("should fail with negative port", async () => {
      Object.assign(process.env, validEnv, { PORT: "-1" });

      const result = await Effect.runPromise(loadConfig.pipe(Effect.either));

      expect(result._tag).toBe("Left");
    });
  });
});
