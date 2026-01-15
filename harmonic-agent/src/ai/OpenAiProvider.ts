import OpenAI from "openai";
import { Effect, Layer } from "effect";
import { ConfigService } from "../config/Config.js";
import { AiProviderError } from "../errors/Errors.js";
import { AiProvider, type Message, type Tool, type AiResponse, type ContentBlock } from "./AiProvider.js";

export const OpenAiProviderLive = Layer.effect(
  AiProvider,
  Effect.gen(function* () {
    const config = yield* ConfigService;

    if (!config.openaiApiKey) {
      return yield* Effect.fail(
        new AiProviderError({
          message: "OPENAI_API_KEY is required for OpenAI provider",
          provider: "openai",
        })
      );
    }

    const client = new OpenAI({
      apiKey: config.openaiApiKey,
    });

    return {
      chat: (systemPrompt: string, messages: Message[], tools: Tool[]) =>
        Effect.gen(function* () {
          const openaiMessages: OpenAI.Chat.ChatCompletionMessageParam[] = [
            { role: "system", content: systemPrompt },
            ...messages.map((msg): OpenAI.Chat.ChatCompletionMessageParam => {
              if (msg.role === "assistant") {
                if (typeof msg.content === "string") {
                  return { role: "assistant", content: msg.content };
                }

                // Handle tool calls in assistant messages
                const toolCalls = msg.content
                  .filter((b) => b.type === "tool_use")
                  .map((b) => ({
                    id: b.id || "",
                    type: "function" as const,
                    function: {
                      name: b.name || "",
                      arguments: JSON.stringify(b.input || {}),
                    },
                  }));

                const textContent = msg.content
                  .filter((b) => b.type === "text")
                  .map((b) => b.text || "")
                  .join("\n");

                if (toolCalls.length > 0) {
                  return {
                    role: "assistant",
                    content: textContent || null,
                    tool_calls: toolCalls,
                  };
                }

                return { role: "assistant", content: textContent };
              }

              // User messages with tool results
              if (typeof msg.content !== "string") {
                const toolResults = msg.content.filter((b) => b.type === "tool_result");
                if (toolResults.length > 0) {
                  // OpenAI expects tool results as separate messages
                  // Return the first one; in practice we'll handle this differently
                  const result = toolResults[0];
                  return {
                    role: "tool",
                    tool_call_id: result?.tool_use_id || "",
                    content: result?.content || "",
                  };
                }

                const textContent = msg.content
                  .filter((b) => b.type === "text")
                  .map((b) => b.text || "")
                  .join("\n");

                return { role: "user", content: textContent };
              }

              return { role: "user", content: msg.content };
            }),
          ];

          const openaiTools: OpenAI.Chat.ChatCompletionTool[] = tools.map((tool) => ({
            type: "function",
            function: {
              name: tool.name,
              description: tool.description,
              parameters: tool.input_schema,
            },
          }));

          const response = yield* Effect.tryPromise({
            try: () =>
              client.chat.completions.create({
                model: config.aiModel,
                messages: openaiMessages,
                tools: openaiTools,
                max_tokens: 4096,
              }),
            catch: (error) =>
              new AiProviderError({
                message: error instanceof Error ? error.message : String(error),
                provider: "openai",
                cause: error,
              }),
          });

          const choice = response.choices[0];
          if (!choice) {
            return yield* Effect.fail(
              new AiProviderError({
                message: "No response from OpenAI",
                provider: "openai",
              })
            );
          }

          const content: ContentBlock[] = [];

          if (choice.message.content) {
            content.push({ type: "text", text: choice.message.content });
          }

          if (choice.message.tool_calls) {
            for (const toolCall of choice.message.tool_calls) {
              content.push({
                type: "tool_use",
                id: toolCall.id,
                name: toolCall.function.name,
                input: JSON.parse(toolCall.function.arguments) as Record<string, unknown>,
              });
            }
          }

          let stopReason: AiResponse["stopReason"] = "end_turn";
          if (choice.finish_reason === "tool_calls") {
            stopReason = "tool_use";
          } else if (choice.finish_reason === "length") {
            stopReason = "max_tokens";
          } else if (choice.finish_reason === "stop") {
            stopReason = "end_turn";
          }

          const aiResponse: AiResponse = {
            content,
            stopReason,
            usage: {
              inputTokens: response.usage?.prompt_tokens || 0,
              outputTokens: response.usage?.completion_tokens || 0,
            },
          };

          return aiResponse;
        }),
    };
  })
);
