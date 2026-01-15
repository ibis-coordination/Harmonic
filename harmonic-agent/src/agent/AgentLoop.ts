import { Context, Effect, Layer, Ref } from "effect";
import { ConfigService } from "../config/Config.js";
import { McpClient } from "../mcp/McpClient.js";
import {
  AiProvider,
  extractToolUses,
  extractTextContent,
  type Message,
  type ContentBlock,
} from "../ai/AiProvider.js";
import { AgentLoopError } from "../errors/Errors.js";
import { AGENT_TOOLS, SYSTEM_PROMPT } from "./AgentContext.js";

export interface AgentSession {
  sessionId: string;
  startTime: number;
  turns: number;
  totalInputTokens: number;
  totalOutputTokens: number;
}

export class AgentLoop extends Context.Tag("AgentLoop")<
  AgentLoop,
  {
    readonly runSession: (sessionId: string) => Effect.Effect<AgentSession, AgentLoopError>;
  }
>() {}

export const AgentLoopLive = Layer.effect(
  AgentLoop,
  Effect.gen(function* () {
    const config = yield* ConfigService;
    const mcpClient = yield* McpClient;
    const aiProvider = yield* AiProvider;

    const runSession = (sessionId: string): Effect.Effect<AgentSession, AgentLoopError> =>
      Effect.gen(function* () {
        const session: AgentSession = {
          sessionId,
          startTime: Date.now(),
          turns: 0,
          totalInputTokens: 0,
          totalOutputTokens: 0,
        };

        const messagesRef = yield* Ref.make<Message[]>([]);

        // Start by navigating to notifications
        const initialNav = yield* Effect.catchAll(
          mcpClient.navigate("/notifications"),
          (error) =>
            Effect.fail(
              new AgentLoopError({
                message: `Failed to navigate to notifications: ${error.message}`,
                cause: error,
              })
            )
        );

        // Add the initial navigation result as the first user message
        yield* Ref.update(messagesRef, (msgs) => [
          ...msgs,
          {
            role: "user" as const,
            content: `You've been woken up by activity. Here are your notifications:\n\n${initialNav.content}`,
          },
        ]);

        console.log(`[${sessionId}] Agent session started, navigated to /notifications`);

        // Main agent loop
        while (
          session.turns < config.maxTurns &&
          session.totalInputTokens + session.totalOutputTokens < config.maxTokensPerSession &&
          Date.now() - session.startTime < config.sessionTimeoutMs
        ) {
          session.turns++;

          const messages = yield* Ref.get(messagesRef);

          // Get AI response
          const response = yield* Effect.catchAll(
            aiProvider.chat(SYSTEM_PROMPT, messages, AGENT_TOOLS),
            (error) =>
              Effect.fail(
                new AgentLoopError({
                  message: `AI provider error: ${error.message}`,
                  cause: error,
                })
              )
          );

          session.totalInputTokens += response.usage.inputTokens;
          session.totalOutputTokens += response.usage.outputTokens;

          // Add assistant response to messages
          yield* Ref.update(messagesRef, (msgs) => [
            ...msgs,
            { role: "assistant" as const, content: response.content },
          ]);

          const textContent = extractTextContent(response);
          if (textContent) {
            console.log(`[${sessionId}] Turn ${session.turns} - AI: ${textContent.slice(0, 200)}...`);
          }

          // Check if we should stop
          if (response.stopReason === "end_turn") {
            console.log(`[${sessionId}] Agent ended session after ${session.turns} turns`);
            break;
          }

          if (response.stopReason === "max_tokens") {
            console.log(`[${sessionId}] Stopped due to max tokens`);
            break;
          }

          // Execute tool calls
          const toolUses = extractToolUses(response);

          if (toolUses.length === 0) {
            console.log(`[${sessionId}] No tool calls, ending session`);
            break;
          }

          const toolResults: ContentBlock[] = [];

          for (const toolUse of toolUses) {
            console.log(`[${sessionId}] Executing tool: ${toolUse.name}`, toolUse.input);

            let result: string;
            let isError = false;

            if (toolUse.name === "navigate") {
              const path = toolUse.input["path"] as string;
              const navResult = yield* Effect.catchAll(
                mcpClient.navigate(path),
                (error) => Effect.succeed({ content: `Error: ${error.message}`, path, error: true })
              );
              result = "error" in navResult ? navResult.content : navResult.content;
              isError = "error" in navResult;
            } else if (toolUse.name === "execute_action") {
              const action = toolUse.input["action"] as string;
              const params = toolUse.input["params"] as Record<string, unknown> | undefined;
              const actionResult = yield* Effect.catchAll(
                mcpClient.executeAction(action, params),
                (error) => Effect.succeed({ content: `Error: ${error.message}`, error: true })
              );
              result = "error" in actionResult ? actionResult.content : actionResult.content;
              isError = "error" in actionResult;
            } else {
              result = `Unknown tool: ${toolUse.name}`;
              isError = true;
            }

            toolResults.push({
              type: "tool_result",
              tool_use_id: toolUse.id,
              content: result,
              is_error: isError,
            });
          }

          // Add tool results as user message
          yield* Ref.update(messagesRef, (msgs) => [
            ...msgs,
            { role: "user" as const, content: toolResults },
          ]);
        }

        // Check why we stopped
        if (session.turns >= config.maxTurns) {
          console.log(`[${sessionId}] Stopped due to max turns (${config.maxTurns})`);
        }
        if (session.totalInputTokens + session.totalOutputTokens >= config.maxTokensPerSession) {
          console.log(`[${sessionId}] Stopped due to token limit`);
        }
        if (Date.now() - session.startTime >= config.sessionTimeoutMs) {
          console.log(`[${sessionId}] Stopped due to timeout`);
        }

        console.log(
          `[${sessionId}] Session complete: ${session.turns} turns, ` +
          `${session.totalInputTokens + session.totalOutputTokens} tokens, ` +
          `${Date.now() - session.startTime}ms`
        );

        return session;
      });

    return { runSession };
  })
);
