import { Data } from "effect";

export class LLMError extends Data.TaggedError("LLMError")<{
  readonly message: string;
  readonly statusCode?: number | undefined;
}> {}

export class HarmonicApiError extends Data.TaggedError("HarmonicApiError")<{
  readonly message: string;
  readonly statusCode?: number | undefined;
  readonly path?: string | undefined;
}> {}

export class TaskCancelledError extends Data.TaggedError("TaskCancelledError")<{
  readonly taskRunId: string;
}> {}

export class PreflightFailedError extends Data.TaggedError("PreflightFailedError")<{
  readonly taskRunId: string;
  readonly reason: string;
}> {}

export class TokenFetchError extends Data.TaggedError("TokenFetchError")<{
  readonly tokenId: string;
  readonly message: string;
}> {}

export class RedisError extends Data.TaggedError("RedisError")<{
  readonly message: string;
}> {}

export class ConfigError extends Data.TaggedError("ConfigError")<{
  readonly message: string;
}> {}

export class TokenDecryptError extends Data.TaggedError("TokenDecryptError")<{
  readonly taskRunId: string;
  readonly message: string;
}> {}
