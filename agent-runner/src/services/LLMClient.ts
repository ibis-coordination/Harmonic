/**
 * OpenAI-compatible LLM client — Effect service.
 * Speaks the standard chat completions API (works with Stripe AI Gateway and LiteLLM).
 */

import { Context, Effect, Layer } from "effect";
import { Config } from "../config/Config.js";
import { LLMError } from "../errors/Errors.js";
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
}

export interface LLMClientService {
  readonly chat: (
    messages: readonly Message[],
    model: string | undefined,
    tools: readonly ToolDefinition[],
    stripeCustomerId: string | undefined,
  ) => Effect.Effect<LLMResponse, LLMError>;
}

export class LLMClient extends Context.Tag("LLMClient")<LLMClient, LLMClientService>() {}

interface CompletionChoice {
  readonly message?: {
    readonly content?: string | null;
    readonly tool_calls?: readonly RawToolCall[];
  };
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

    const chat: LLMClientService["chat"] = (messages, model, tools, stripeCustomerId) =>
      Effect.tryPromise({
        try: async () => {
          const endpoint = config.llmGatewayMode === "stripe_gateway"
            ? "/chat/completions"
            : "/v1/chat/completions";

          const headers: Record<string, string> = {
            "Content-Type": "application/json",
          };

          if (config.llmGatewayMode === "stripe_gateway") {
            if (config.stripeGatewayKey === undefined) {
              throw new Error("STRIPE_GATEWAY_KEY is required in stripe_gateway mode");
            }
            headers["Authorization"] = `Bearer ${config.stripeGatewayKey}`;
            if (stripeCustomerId !== undefined) {
              headers["X-Stripe-Customer-ID"] = stripeCustomerId;
            }
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

          const url = `${config.llmBaseUrl}${endpoint}`;
          const response = await fetch(url, {
            method: "POST",
            headers,
            body,
            signal: AbortSignal.timeout(120_000),
          });

          if (!response.ok) {
            const errorBody = await response.text().catch(() => "");
            if (response.status === 402) {
              throw new Error("Payment required. Please check your billing setup.");
            }
            if (response.status === 429) {
              throw new Error("Rate limited by LLM provider. Please try again later.");
            }
            throw new Error(`LLM request failed with status ${response.status}: ${errorBody.slice(0, 500)}`);
          }

          const data = await response.json() as CompletionResponse;
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

          return {
            content: message?.content ?? undefined,
            toolCalls,
            finishReason: choice?.finish_reason ?? "stop",
            model: data.model ?? undefined,
            usage: {
              inputTokens: data.usage?.prompt_tokens ?? 0,
              outputTokens: data.usage?.completion_tokens ?? 0,
            },
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
