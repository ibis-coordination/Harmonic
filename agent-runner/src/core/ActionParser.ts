/**
 * Parse LLM responses into typed actions — pure functions.
 */

import type { ToolCall } from "./PromptBuilder.js";

export type AgentAction =
  | {
      readonly type: "fetch_page";
      readonly path: string;
      readonly context: Record<string, unknown> | undefined;
    }
  | {
      readonly type: "execute_action";
      readonly context: Record<string, unknown>;
      readonly path: string;
      readonly action: string;
      readonly params: Record<string, unknown> | undefined;
    }
  | { readonly type: "search"; readonly query: string }
  | { readonly type: "get_help"; readonly topic: string }
  | { readonly type: "respond_to_human"; readonly message: string }
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
    case "fetch_page": {
      const path = args["path"];
      if (typeof path !== "string" || path === "") {
        return { type: "error", message: "fetch_page requires a non-empty 'path' string" };
      }
      // Optional `context` block — only needed for representation reads.
      // When present it must be a plain object; primitives / arrays are
      // rejected at the parser layer so a structural mistake doesn't reach
      // the wire as a silently-dropped field.
      const rawContext = args["context"];
      let context: Record<string, unknown> | undefined;
      if (rawContext !== undefined && rawContext !== null) {
        if (typeof rawContext !== "object" || Array.isArray(rawContext)) {
          return { type: "error", message: "fetch_page `context` must be an object when present" };
        }
        context = rawContext as Record<string, unknown>;
      }
      return { type: "fetch_page", path, context };
    }
    case "execute_action": {
      const context = args["context"];
      if (typeof context !== "object" || context === null || Array.isArray(context)) {
        return { type: "error", message: "execute_action requires a 'context' object (identity, visibility, intention)" };
      }
      const path = args["path"];
      if (typeof path !== "string" || path === "") {
        return { type: "error", message: "execute_action requires a non-empty 'path' string" };
      }
      const action = args["action"];
      if (typeof action !== "string" || action === "") {
        return { type: "error", message: "execute_action requires a non-empty 'action' string" };
      }
      const params = typeof args["params"] === "object" && args["params"] !== null
        ? args["params"] as Record<string, unknown>
        : undefined;
      return { type: "execute_action", context: context as Record<string, unknown>, path, action, params };
    }
    case "search": {
      const query = args["query"];
      if (typeof query !== "string" || query === "") {
        return { type: "error", message: "search requires a non-empty 'query' string" };
      }
      return { type: "search", query };
    }
    case "get_help": {
      const topic = args["topic"];
      if (typeof topic !== "string" || topic === "") {
        return { type: "error", message: "get_help requires a non-empty 'topic' string" };
      }
      return { type: "get_help", topic };
    }
    case "respond_to_human": {
      const message = args["message"];
      if (typeof message !== "string" || message === "") {
        return { type: "error", message: "respond_to_human requires a non-empty 'message' string" };
      }
      return { type: "respond_to_human", message };
    }
    default:
      return { type: "error", message: `Unknown tool: ${name}` };
  }
}
