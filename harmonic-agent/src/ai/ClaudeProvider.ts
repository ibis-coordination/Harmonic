import Anthropic from "@anthropic-ai/sdk";
import { Effect, Layer } from "effect";
import { ConfigService } from "../config/Config.js";
import { AiProviderError } from "../errors/Errors.js";
import { AiProvider, type Message, type Tool, type AiResponse, type ContentBlock } from "./AiProvider.js";

export const ClaudeProviderLive = Layer.effect(
  AiProvider,
  Effect.gen(function* () {
    const config = yield* ConfigService;

    if (!config.anthropicApiKey) {
      return yield* Effect.fail(
        new AiProviderError({
          message: "ANTHROPIC_API_KEY is required for Claude provider",
          provider: "claude",
        })
      );
    }

    const client = new Anthropic({
      apiKey: config.anthropicApiKey,
    });

    return {
      chat: (systemPrompt: string, messages: Message[], tools: Tool[]) =>
        Effect.gen(function* () {
          const anthropicMessages: Anthropic.MessageParam[] = messages.map((msg) => ({
            role: msg.role,
            content: typeof msg.content === "string"
              ? msg.content
              : msg.content.map((block) => {
                  if (block.type === "text") {
                    return { type: "text" as const, text: block.text || "" };
                  }
                  if (block.type === "tool_use") {
                    return {
                      type: "tool_use" as const,
                      id: block.id || "",
                      name: block.name || "",
                      input: block.input || {},
                    };
                  }
                  if (block.type === "tool_result") {
                    return {
                      type: "tool_result" as const,
                      tool_use_id: block.tool_use_id || "",
                      content: block.content || "",
                      is_error: block.is_error,
                    };
                  }
                  return { type: "text" as const, text: "" };
                }),
          }));

          const anthropicTools: Anthropic.Tool[] = tools.map((tool) => ({
            name: tool.name,
            description: tool.description,
            input_schema: tool.input_schema as Anthropic.Tool.InputSchema,
          }));

          const response = yield* Effect.tryPromise({
            try: () =>
              client.messages.create({
                model: config.aiModel,
                max_tokens: 4096,
                system: systemPrompt,
                messages: anthropicMessages,
                tools: anthropicTools,
              }),
            catch: (error) =>
              new AiProviderError({
                message: error instanceof Error ? error.message : String(error),
                provider: "claude",
                cause: error,
              }),
          });

          const content: ContentBlock[] = response.content.map((block) => {
            if (block.type === "text") {
              return { type: "text" as const, text: block.text };
            }
            if (block.type === "tool_use") {
              return {
                type: "tool_use" as const,
                id: block.id,
                name: block.name,
                input: block.input as Record<string, unknown>,
              };
            }
            return { type: "text" as const, text: "" };
          });

          const aiResponse: AiResponse = {
            content,
            stopReason: response.stop_reason as AiResponse["stopReason"],
            usage: {
              inputTokens: response.usage.input_tokens,
              outputTokens: response.usage.output_tokens,
            },
          };

          return aiResponse;
        }),
    };
  })
);
