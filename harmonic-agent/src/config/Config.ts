import { Context, Effect, Layer, Schema } from "effect";
import { ConfigError } from "../errors/Errors.js";

const AiProviderSchema = Schema.Union(
  Schema.Literal("claude"),
  Schema.Literal("openai")
);

export type AiProviderType = Schema.Schema.Type<typeof AiProviderSchema>;

const ConfigSchema = Schema.Struct({
  port: Schema.NumberFromString.pipe(Schema.int(), Schema.positive()),
  host: Schema.String,
  harmonicBaseUrl: Schema.String.pipe(Schema.startsWith("http")),
  harmonicApiToken: Schema.String.pipe(Schema.minLength(1)),
  webhookSecret: Schema.String.pipe(Schema.minLength(1)),
  aiProvider: AiProviderSchema,
  anthropicApiKey: Schema.optional(Schema.String),
  openaiApiKey: Schema.optional(Schema.String),
  aiModel: Schema.String,
  maxTurns: Schema.NumberFromString.pipe(Schema.int(), Schema.positive()),
  maxTokensPerSession: Schema.NumberFromString.pipe(Schema.int(), Schema.positive()),
  sessionTimeoutMs: Schema.NumberFromString.pipe(Schema.int(), Schema.positive()),
});

export type Config = Schema.Schema.Type<typeof ConfigSchema>;

export class ConfigService extends Context.Tag("ConfigService")<
  ConfigService,
  Config
>() {}

function getEnv(key: string, defaultValue?: string): string {
  const value = process.env[key] ?? defaultValue;
  if (value === undefined) {
    throw new Error(`Missing required environment variable: ${key}`);
  }
  return value;
}

const loadConfigFromEnv = Effect.try({
  try: () => ({
    port: getEnv("PORT", "3001"),
    host: getEnv("HOST", "0.0.0.0"),
    harmonicBaseUrl: getEnv("HARMONIC_BASE_URL"),
    harmonicApiToken: getEnv("HARMONIC_API_TOKEN"),
    webhookSecret: getEnv("WEBHOOK_SECRET"),
    aiProvider: getEnv("AI_PROVIDER", "claude"),
    anthropicApiKey: process.env["ANTHROPIC_API_KEY"],
    openaiApiKey: process.env["OPENAI_API_KEY"],
    aiModel: getEnv("AI_MODEL", "claude-sonnet-4-20250514"),
    maxTurns: getEnv("MAX_TURNS", "20"),
    maxTokensPerSession: getEnv("MAX_TOKENS_PER_SESSION", "100000"),
    sessionTimeoutMs: getEnv("SESSION_TIMEOUT_MS", "300000"),
  }),
  catch: (error) =>
    new ConfigError({
      message: error instanceof Error ? error.message : String(error),
    }),
});

const parseConfig = (raw: Record<string, unknown>) =>
  Effect.mapError(
    Schema.decodeUnknown(ConfigSchema)(raw),
    (parseError) =>
      new ConfigError({
        message: `Config validation failed: ${parseError.message}`,
      })
  );

const validateApiKeys = (config: Config) =>
  Effect.gen(function* () {
    if (config.aiProvider === "claude" && !config.anthropicApiKey) {
      return yield* Effect.fail(
        new ConfigError({
          message: "ANTHROPIC_API_KEY is required when AI_PROVIDER is claude",
          field: "anthropicApiKey",
        })
      );
    }
    if (config.aiProvider === "openai" && !config.openaiApiKey) {
      return yield* Effect.fail(
        new ConfigError({
          message: "OPENAI_API_KEY is required when AI_PROVIDER is openai",
          field: "openaiApiKey",
        })
      );
    }
    return config;
  });

export const loadConfig: Effect.Effect<Config, ConfigError> = Effect.gen(function* () {
  const raw = yield* loadConfigFromEnv;
  const config = yield* parseConfig(raw);
  return yield* validateApiKeys(config);
});

export const ConfigLive = Layer.effect(ConfigService, loadConfig);
