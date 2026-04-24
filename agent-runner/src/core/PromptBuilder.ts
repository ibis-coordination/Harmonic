/**
 * Message construction for the LLM conversation — pure functions.
 */

import { buildSystemPrompt, AGENT_TOOLS } from "./AgentContext.js";
import type { ToolDefinition } from "./AgentContext.js";

export interface Message {
  readonly role: "system" | "user" | "assistant" | "tool";
  readonly content?: string | undefined;
  readonly tool_calls?: readonly ToolCall[] | undefined;
  readonly tool_call_id?: string | undefined;
}

export interface ToolCall {
  readonly id: string;
  readonly type: "function";
  readonly function: {
    readonly name: string;
    readonly arguments: string;
  };
}

export interface TaskPayload {
  readonly taskRunId: string;
  readonly encryptedToken: string;
  readonly task: string;
  readonly maxSteps: number;
  readonly model: string | undefined;
  readonly agentId: string;
  readonly tenantSubdomain: string;
  readonly stripeCustomerStripeId: string | undefined;
  readonly mode: "task" | "chat_turn";
  readonly chatSessionId: string | undefined;
}

/**
 * Build the initial message array for a new agent task.
 */
export function buildInitialMessages(
  task: TaskPayload,
  identityContent: string,
  scratchpad: string | undefined,
): readonly Message[] {
  return [
    systemMessage(buildSystemPrompt(identityContent, scratchpad)),
    userMessage(task.task),
  ];
}

/**
 * Build tool result messages from completed tool calls.
 */
export function buildToolResultMessages(
  toolCalls: readonly ToolCall[],
  results: readonly string[],
): readonly Message[] {
  return toolCalls.map((tc, i): Message => ({
    role: "tool",
    content: results[i] ?? "Error: no result",
    tool_call_id: tc.id,
  }));
}

export function systemMessage(content: string): Message {
  return { role: "system", content };
}

export function userMessage(content: string): Message {
  return { role: "user", content };
}

export function assistantMessage(
  content: string | undefined,
  toolCalls: readonly ToolCall[] | undefined,
): Message {
  return {
    role: "assistant",
    content: content ?? undefined,
    tool_calls: toolCalls !== undefined && toolCalls.length > 0 ? toolCalls : undefined,
  };
}

/**
 * Get the tool definitions for chat completions requests.
 */
export function getToolDefinitions(): readonly ToolDefinition[] {
  return AGENT_TOOLS;
}
