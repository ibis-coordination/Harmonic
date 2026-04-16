/**
 * Parse LLM responses into typed actions — pure functions.
 */

import type { ToolCall } from "./PromptBuilder.js";

export type AgentAction =
  | { readonly type: "navigate"; readonly path: string }
  | { readonly type: "execute_action"; readonly action: string; readonly params: Record<string, unknown> | undefined }
  | { readonly type: "done"; readonly content: string }
  | { readonly type: "error"; readonly message: string };

/**
 * Parse tool calls from an LLM response into typed agent actions.
 * If no tool calls, the response is treated as "done" (agent chose to stop).
 */
export function parseToolCalls(
  toolCalls: readonly ToolCall[] | undefined,
  content: string | undefined,
): readonly AgentAction[] {
  if (toolCalls === undefined || toolCalls.length === 0) {
    return [{ type: "done", content: content ?? "" }];
  }

  return toolCalls.map(parseToolCall);
}

function parseToolCall(toolCall: ToolCall): AgentAction {
  const name = toolCall.function.name;
  let args: Record<string, unknown>;

  try {
    args = JSON.parse(toolCall.function.arguments) as Record<string, unknown>;
  } catch {
    return { type: "error", message: `Invalid JSON in tool call arguments for ${name}` };
  }

  switch (name) {
    case "navigate": {
      const path = args["path"];
      if (typeof path !== "string" || path === "") {
        return { type: "error", message: "navigate requires a non-empty 'path' string" };
      }
      return { type: "navigate", path };
    }
    case "execute_action": {
      const action = args["action"];
      if (typeof action !== "string" || action === "") {
        return { type: "error", message: "execute_action requires a non-empty 'action' string" };
      }
      const params = typeof args["params"] === "object" && args["params"] !== null
        ? args["params"] as Record<string, unknown>
        : undefined;
      return { type: "execute_action", action, params };
    }
    default:
      return { type: "error", message: `Unknown tool: ${name}` };
  }
}

/**
 * Validate an action against the available actions on the current page.
 */
export function validateAction(
  actionName: string,
  availableActions: readonly string[],
): { readonly valid: boolean; readonly error?: string | undefined } {
  if (availableActions.includes(actionName)) {
    return { valid: true };
  }
  return {
    valid: false,
    error: `Action "${actionName}" is not available. Available: ${availableActions.join(", ")}`,
  };
}
