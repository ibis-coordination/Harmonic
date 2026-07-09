import { Context, Effect, Layer } from "effect";
import { ConfigError } from "../errors/Errors.js";

export interface AppConfig {
  readonly harmonicInternalUrl: string;
  readonly harmonicHostname: string;
  readonly agentRunnerSecret: string;
  readonly redisUrl: string;
  readonly litellmBaseUrl: string;
  /** The Harmonic LLM gateway — where the runner sends billed (stripe_gateway) calls. */
  readonly llmGatewayUrl: string;
  /** The Stripe AI Gateway upstream — used by the gateway entrypoint, not the runner. */
  readonly stripeGatewayBaseUrl: string;
  /** Fallback route for tasks whose payload carries no llm_gateway_mode. */
  readonly llmGatewayMode: "litellm" | "stripe_gateway";
  readonly stripeGatewayKey: string | undefined;
  readonly streamName: string;
  readonly consumerGroup: string;
  readonly consumerName: string;
  readonly maxConcurrentTasks: number;
  readonly streamMaxLen: number;
}

export class Config extends Context.Tag("Config")<Config, AppConfig>() {}

const requireEnv = (name: string): Effect.Effect<string, ConfigError> =>
  Effect.suspend(() => {
    const value = process.env[name];
    if (value === undefined || value === "") {
      return Effect.fail(new ConfigError({ message: `Missing required environment variable: ${name}` }));
    }
    return Effect.succeed(value);
  });

const optionalEnv = (name: string, defaultValue: string): Effect.Effect<string, never> =>
  Effect.succeed(process.env[name] ?? defaultValue);

export const ConfigLive = Layer.effect(
  Config,
  Effect.gen(function* () {
    const agentRunnerSecret = yield* requireEnv("AGENT_RUNNER_SECRET");
    const harmonicHostname = yield* requireEnv("HARMONIC_HOSTNAME");
    const redisUrl = yield* optionalEnv("REDIS_URL", "redis://redis:6379");
    const llmGatewayMode = yield* optionalEnv("LLM_GATEWAY_MODE", "litellm");
    const harmonicInternalUrl = yield* optionalEnv("HARMONIC_INTERNAL_URL", "http://web:3000");
    // LLM_BASE_URL historically overrode the single boot-mode endpoint; keep
    // honoring it for whichever mode the env declares, with per-route
    // overrides available via the explicit vars.
    const llmBaseUrl = process.env["LLM_BASE_URL"];
    const litellmBaseUrl = yield* optionalEnv(
      "LITELLM_BASE_URL",
      (llmGatewayMode === "litellm" ? llmBaseUrl : undefined) ?? "http://litellm:4000",
    );
    const stripeGatewayBaseUrl = yield* optionalEnv(
      "STRIPE_GATEWAY_BASE_URL",
      (llmGatewayMode === "stripe_gateway" ? llmBaseUrl : undefined) ?? "https://llm.stripe.com",
    );
    const llmGatewayUrl = yield* optionalEnv("LLM_GATEWAY_URL", "http://llm-gateway:4500");
    const stripeGatewayKey = process.env["STRIPE_GATEWAY_KEY"];
    const streamName = yield* optionalEnv("AGENT_TASKS_STREAM", "agent_tasks");
    const consumerGroup = yield* optionalEnv("AGENT_TASKS_CONSUMER_GROUP", "agent_runner");
    const consumerName = yield* optionalEnv("AGENT_TASKS_CONSUMER_NAME", `runner-${process.pid}`);
    const maxConcurrentStr = yield* optionalEnv("MAX_CONCURRENT_TASKS", "100");
    const streamMaxLenStr = yield* optionalEnv("STREAM_MAX_LEN", "10000");

    if (llmGatewayMode !== "litellm" && llmGatewayMode !== "stripe_gateway") {
      return yield* Effect.fail(
        new ConfigError({ message: `Invalid LLM_GATEWAY_MODE: ${llmGatewayMode}. Must be 'litellm' or 'stripe_gateway'` }),
      );
    }

    return {
      harmonicInternalUrl,
      harmonicHostname,
      agentRunnerSecret,
      redisUrl,
      litellmBaseUrl,
      llmGatewayUrl,
      stripeGatewayBaseUrl,
      llmGatewayMode: llmGatewayMode as "litellm" | "stripe_gateway",
      stripeGatewayKey,
      streamName,
      consumerGroup,
      consumerName,
      maxConcurrentTasks: parseInt(maxConcurrentStr, 10) || 100,
      streamMaxLen: parseInt(streamMaxLenStr, 10) || 10000,
    };
  }),
);
