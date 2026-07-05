import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { Effect } from "effect";
import { Config, ConfigLive } from "../../src/config/Config.js";

function loadConfig() {
  return Effect.runPromise(
    Effect.gen(function* () {
      return yield* Config;
    }).pipe(Effect.provide(ConfigLive)),
  );
}

describe("Config LLM base URLs", () => {
  beforeEach(() => {
    vi.stubEnv("AGENT_RUNNER_SECRET", "test-secret");
    vi.stubEnv("HARMONIC_HOSTNAME", "test.local");
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("defaults both base URLs", async () => {
    const config = await loadConfig();
    expect(config.litellmBaseUrl).toBe("http://litellm:4000");
    expect(config.stripeGatewayBaseUrl).toBe("https://llm.stripe.com");
  });

  it("honors LLM_BASE_URL for the litellm route when boot mode is litellm", async () => {
    vi.stubEnv("LLM_BASE_URL", "http://custom-litellm:5000");
    const config = await loadConfig();
    expect(config.litellmBaseUrl).toBe("http://custom-litellm:5000");
    expect(config.stripeGatewayBaseUrl).toBe("https://llm.stripe.com");
  });

  it("honors LLM_BASE_URL for the gateway route when boot mode is stripe_gateway", async () => {
    vi.stubEnv("LLM_GATEWAY_MODE", "stripe_gateway");
    vi.stubEnv("LLM_BASE_URL", "https://gateway-proxy.test");
    const config = await loadConfig();
    expect(config.stripeGatewayBaseUrl).toBe("https://gateway-proxy.test");
    expect(config.litellmBaseUrl).toBe("http://litellm:4000");
  });
});
