/**
 * OpenAI-compatible LLM client — Effect service.
 * Speaks the standard chat completions API (works with Stripe AI Gateway and LiteLLM).
 */

import { Context, Effect, Layer } from "effect";
import { Config } from "../config/Config.js";
import { LLMError } from "../errors/Errors.js";
import { log } from "./Logger.js";
import type { Message, ToolCall } from "../core/PromptBuilder.js";
import type { ToolDefinition } from "../core/AgentContext.js";

export interface LLMResponse {
  readonly content: string | undefined;
  readonly toolCalls: readonly ToolCall[];
  readonly finishReason: string;
  readonly model: string | undefined;
  readonly usage: {
    readonly inputTokens: number;
    readonly outputTokens: number;
  };
  /**
   * Model-emitted chain-of-thought / reasoning text, when the provider exposes
   * it as a separate field. Different vendors use different shapes — we
   * normalize to a single optional string. Undefined when: not a reasoning
   * model, or reasoning hidden by the provider.
   */
  readonly reasoning: string | undefined;
}

export interface LLMClientService {
  readonly chat: (
    messages: readonly Message[],
    model: string | undefined,
    tools: readonly ToolDefinition[],
    stripeCustomerId: string | undefined,
    gatewayMode?: "litellm" | "stripe_gateway",
  ) => Effect.Effect<LLMResponse, LLMError>;
}

export class LLMClient extends Context.Tag("LLMClient")<LLMClient, LLMClientService>() {}

interface CompletionChoice {
  readonly message?: {
    readonly content?: string | null;
    readonly tool_calls?: readonly RawToolCall[];
    // Reasoning models surface chain-of-thought in different fields:
    //   reasoning_content — DeepSeek R1, Anthropic via LiteLLM passthrough
    //   reasoning         — some OpenRouter providers
    readonly reasoning_content?: string | null;
    readonly reasoning?: string | null;
  };
  // OpenAI o-series surfaces reasoning at the choice level instead.
  readonly reasoning?: string | null;
  readonly finish_reason?: string;
}

interface RawToolCall {
  readonly id?: string;
  readonly type?: string;
  readonly function?: {
    readonly name?: string;
    readonly arguments?: string;
  };
}

interface CompletionResponse {
  readonly choices?: readonly CompletionChoice[];
  readonly model?: string;
  readonly usage?: {
    readonly prompt_tokens?: number;
    readonly completion_tokens?: number;
  };
}

export const LLMClientLive = Layer.effect(
  LLMClient,
  Effect.gen(function* () {
    const config = yield* Config;

    const chat: LLMClientService["chat"] = (messages, model, tools, stripeCustomerId, gatewayMode) =>
      Effect.tryPromise({
        try: async () => {
          const mode = gatewayMode ?? config.llmGatewayMode;
          const baseUrl = mode === "stripe_gateway" ? config.stripeGatewayBaseUrl : config.litellmBaseUrl;
          const endpoint = mode === "stripe_gateway"
            ? "/chat/completions"
            : "/v1/chat/completions";

          const headers: Record<string, string> = {
            "Content-Type": "application/json",
          };

          if (mode === "stripe_gateway") {
            if (config.stripeGatewayKey === undefined) {
              throw new Error("STRIPE_GATEWAY_KEY is required in stripe_gateway mode");
            }
            if (stripeCustomerId === undefined) {
              // Without the customer header the gateway would bill the platform
              // account instead of the tenant — refuse rather than eat the cost.
              throw new Error("stripe_gateway mode requires a stripe customer id for billing attribution");
            }
            headers["Authorization"] = `Bearer ${config.stripeGatewayKey}`;
            headers["X-Stripe-Customer-ID"] = stripeCustomerId;
          }

          const body = JSON.stringify({
            model: model ?? "default",
            messages: messages.map((m) => {
              const msg: Record<string, unknown> = { role: m.role };
              if (m.content !== undefined) msg["content"] = m.content;
              if (m.tool_calls !== undefined) msg["tool_calls"] = m.tool_calls;
              if (m.tool_call_id !== undefined) msg["tool_call_id"] = m.tool_call_id;
              return msg;
            }),
            tools: tools.length > 0 ? tools : undefined,
            max_tokens: 4096,
          });

          const url = `${baseUrl}${endpoint}`;
          const startedAt = Date.now();
          const response = await fetch(url, {
            method: "POST",
            headers,
            body,
            signal: AbortSignal.timeout(120_000),
          });
          const durationMs = Date.now() - startedAt;

          // Routing fields only — never the customer id itself.
          const requestLogFields = {
            gateway_mode: mode,
            model: model ?? "default",
            status_code: response.status,
            duration_ms: durationMs,
            stripe_customer_present: stripeCustomerId !== undefined,
          };

          if (!response.ok) {
            const errorBody = await response.text().catch(() => "");
            log.warn({
              event: "llm_request_failed",
              ...requestLogFields,
              error_body: errorBody.slice(0, 200),
            });
            if (response.status === 402) {
              throw new Error("Payment required. Please check your billing setup.");
            }
            if (response.status === 429) {
              throw new Error("Rate limited by LLM provider. Please try again later.");
            }
            throw new Error(`LLM request failed with status ${response.status}: ${errorBody.slice(0, 500)}`);
          }

          const data = await response.json() as CompletionResponse;
          log.info({
            event: "llm_request",
            ...requestLogFields,
            input_tokens: data.usage?.prompt_tokens ?? 0,
            output_tokens: data.usage?.completion_tokens ?? 0,
          });
          const choice = data.choices?.[0];
          const message = choice?.message;

          const toolCalls: ToolCall[] = (message?.tool_calls ?? [])
            .filter((tc): tc is Required<Pick<RawToolCall, "id" | "function">> & RawToolCall =>
              tc.id !== undefined && tc.function !== undefined)
            .map((tc) => ({
              id: tc.id,
              type: "function" as const,
              function: {
                name: tc.function.name ?? "",
                arguments: tc.function.arguments ?? "{}",
              },
            }));

          const reasoning =
            message?.reasoning_content ??
            message?.reasoning ??
            choice?.reasoning ??
            undefined;

          return {
            content: message?.content ?? undefined,
            toolCalls,
            finishReason: choice?.finish_reason ?? "stop",
            model: data.model ?? undefined,
            usage: {
              inputTokens: data.usage?.prompt_tokens ?? 0,
              outputTokens: data.usage?.completion_tokens ?? 0,
            },
            reasoning: reasoning ?? undefined,
          } satisfies LLMResponse;
        },
        catch: (error) =>
          new LLMError({
            message: error instanceof Error ? error.message : String(error),
          }),
      });

    return { chat };
  }),
);
