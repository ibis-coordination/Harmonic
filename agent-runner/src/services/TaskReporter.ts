/**
 * Reports task lifecycle events to Rails internal API — Effect service.
 * All requests are HMAC-signed and sent to /internal/agent-runner/ endpoints.
 *
 * URLs are built with the tenant subdomain so Rails sees the correct Host
 * header and resolves tenant the same way it does for external requests.
 * The actual TCP connection is routed via the RailsHttp dispatcher — see
 * RailsHttp.ts for why the URL and TCP target are deliberately separated.
 */

import { Context, Effect, Layer, Schedule } from "effect";
import { Config } from "../config/Config.js";
import { HarmonicApiError, PreflightFailedError, TaskCancelledError } from "../errors/Errors.js";
import { buildHeaders } from "./HmacSigner.js";
import { RailsHttp } from "./RailsHttp.js";
import type { StepRecord } from "../core/StepBuilder.js";

/**
 * Retry an Effect that may fail with HarmonicApiError, retrying only on
 * transient errors (5xx or connection failures). 4xx errors are permanent
 * and not retried. Up to 3 retries with exponential backoff (250ms, 1s, 4s).
 */
export const retryOnTransient = <A>(
  effect: Effect.Effect<A, HarmonicApiError>,
): Effect.Effect<A, HarmonicApiError> =>
  effect.pipe(
    Effect.retry({
      times: 3,
      schedule: Schedule.exponential("250 millis"),
      while: (error) => {
        // No statusCode = connection error → retry
        if (error.statusCode === undefined) return true;
        // 5xx = server error → retry
        if (error.statusCode >= 500) return true;
        // 4xx (including 409 Conflict) = permanent → don't retry
        return false;
      },
    }),
  );

export interface TaskResult {
  readonly success: boolean;
  readonly finalMessage: string | undefined;
  readonly error: string | undefined;
  readonly stepsData: readonly StepRecord[];
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
}

export interface TaskReporterService {
  readonly preflight: (taskRunId: string, subdomain: string) => Effect.Effect<void, PreflightFailedError>;
  readonly claim: (taskRunId: string, subdomain: string) => Effect.Effect<void, HarmonicApiError>;
  readonly step: (taskRunId: string, subdomain: string, steps: readonly StepRecord[]) => Effect.Effect<void, HarmonicApiError>;
  readonly complete: (taskRunId: string, subdomain: string, result: TaskResult) => Effect.Effect<void, HarmonicApiError>;
  readonly fail: (taskRunId: string, subdomain: string, error: string) => Effect.Effect<void, HarmonicApiError>;
  readonly scratchpad: (taskRunId: string, subdomain: string, content: string) => Effect.Effect<void, HarmonicApiError>;
  readonly checkCancellation: (taskRunId: string, subdomain: string) => Effect.Effect<void, TaskCancelledError | HarmonicApiError>;
}

export class TaskReporter extends Context.Tag("TaskReporter")<TaskReporter, TaskReporterService>() {}

export const TaskReporterLive = Layer.effect(
  TaskReporter,
  Effect.gen(function* () {
    const config = yield* Config;
    const railsHttp = yield* RailsHttp;

    const internalRequest = (
      method: "GET" | "POST" | "PUT" | "DELETE",
      path: string,
      subdomain: string,
      body?: Record<string, unknown>,
    ): Effect.Effect<unknown, HarmonicApiError> =>
      Effect.tryPromise({
        try: async () => {
          const hasBody = method !== "GET" && body !== undefined;
          const bodyStr = hasBody ? JSON.stringify(body) : "";
          const hmacHeaders = buildHeaders(bodyStr, config.agentRunnerSecret);

          const response = await railsHttp.request(
            hasBody
              ? { method, subdomain, path, headers: { ...hmacHeaders }, body: bodyStr, timeoutMs: 10_000 }
              : { method, subdomain, path, headers: { ...hmacHeaders }, timeoutMs: 10_000 },
          );

          const text = await response.text();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            const err = new Error(`Internal API ${path} failed: HTTP ${response.statusCode} - ${text.slice(0, 500)}`);
            (err as any).statusCode = response.statusCode;
            throw err;
          }
          return text.length > 0 ? JSON.parse(text) as unknown : null;
        },
        catch: (error) =>
          new HarmonicApiError({
            message: error instanceof Error ? error.message : String(error),
            statusCode: (error as any)?.statusCode as number | undefined,
            path,
          }),
      });

    const preflight: TaskReporterService["preflight"] = (taskRunId, subdomain) =>
      Effect.gen(function* () {
        const result = yield* internalRequest("POST", `/internal/agent-runner/tasks/${taskRunId}/preflight`, subdomain, {}).pipe(
          Effect.mapError((e) => new PreflightFailedError({ taskRunId, reason: e.message })),
        );
        const obj = result as Record<string, unknown> | null;
        if (obj?.["status"] !== "ok") {
          const reason = typeof obj?.["reason"] === "string" ? obj["reason"] : "Preflight check failed";
          return yield* Effect.fail(new PreflightFailedError({ taskRunId, reason }));
        }
      });

    const claim: TaskReporterService["claim"] = (taskRunId, subdomain) =>
      internalRequest("POST", `/internal/agent-runner/tasks/${taskRunId}/claim`, subdomain, {}).pipe(
        Effect.asVoid,
      );

    const step: TaskReporterService["step"] = (taskRunId, subdomain, steps) =>
      internalRequest("POST", `/internal/agent-runner/tasks/${taskRunId}/step`, subdomain, { steps }).pipe(
        Effect.asVoid,
      );

    const complete: TaskReporterService["complete"] = (taskRunId, subdomain, result) =>
      retryOnTransient(
        internalRequest("POST", `/internal/agent-runner/tasks/${taskRunId}/complete`, subdomain, {
          success: result.success,
          final_message: result.finalMessage,
          error: result.error,
          steps_data: result.stepsData,
          steps_count: result.stepsData.length,
          input_tokens: result.inputTokens,
          output_tokens: result.outputTokens,
          total_tokens: result.totalTokens,
        }),
      ).pipe(Effect.asVoid);

    const fail: TaskReporterService["fail"] = (taskRunId, subdomain, error) =>
      retryOnTransient(
        internalRequest("POST", `/internal/agent-runner/tasks/${taskRunId}/fail`, subdomain, { error }),
      ).pipe(Effect.asVoid);

    const scratchpad: TaskReporterService["scratchpad"] = (taskRunId, subdomain, content) =>
      retryOnTransient(
        internalRequest("PUT", `/internal/agent-runner/tasks/${taskRunId}/scratchpad`, subdomain, { scratchpad: content }),
      ).pipe(Effect.asVoid);

    const checkCancellation: TaskReporterService["checkCancellation"] = (taskRunId, subdomain) =>
      Effect.gen(function* () {
        const result = yield* internalRequest("GET", `/internal/agent-runner/tasks/${taskRunId}/status`, subdomain);
        const obj = result as Record<string, unknown> | null;
        if (obj?.["status"] === "cancelled") {
          return yield* Effect.fail(new TaskCancelledError({ taskRunId }));
        }
      });

    return { preflight, claim, step, complete, fail, scratchpad, checkCancellation };
  }),
);
