import { Data } from "effect";

export class ConfigError extends Data.TaggedError("ConfigError")<{
  readonly message: string;
  readonly field?: string;
}> {}

export class WebhookVerificationError extends Data.TaggedError("WebhookVerificationError")<{
  readonly message: string;
}> {}

export class McpClientError extends Data.TaggedError("McpClientError")<{
  readonly message: string;
  readonly statusCode?: number;
  readonly path?: string;
}> {}

export class AiProviderError extends Data.TaggedError("AiProviderError")<{
  readonly message: string;
  readonly provider: string;
  readonly cause?: unknown;
}> {}

export class AgentLoopError extends Data.TaggedError("AgentLoopError")<{
  readonly message: string;
  readonly cause?: unknown;
}> {}

export class QueueError extends Data.TaggedError("QueueError")<{
  readonly message: string;
}> {}

export type AppError =
  | ConfigError
  | WebhookVerificationError
  | McpClientError
  | AiProviderError
  | AgentLoopError
  | QueueError;
