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
  /** Set by Rails at dispatch; undefined for payloads published before the field existed. */
  readonly llmGatewayMode: "litellm" | "stripe_gateway" | undefined;
  readonly mode: "task" | "chat_turn";
  readonly chatSessionId: string | undefined;
}

/**
 * Build the initial message array for a new agent task.
 */
export function buildInitialMessages(
  task: TaskPayload,
  identityContent: string,
): readonly Message[] {
  return [
    systemMessage(buildSystemPrompt(identityContent)),
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

/** Tools whose results are page content — candidates for truncation and eliding. */
const PAGE_TOOLS = new Set(["fetch_page", "search", "get_help"]);

/** How many of the most recent page-fetch results stay full when eliding. */
const ELIDE_KEEP_LAST = 2;

/** Stale page results at or under this size aren't worth replacing with a stub. */
const ELIDE_MIN_LENGTH = 500;

/**
 * Cap page content handed to the LLM, with a visible, actionable marker.
 *
 * The marker matters: a silent cut leaves the model looking at a thread that
 * just stops, with no way to know content is missing or how to get it —
 * it will guess. With the marker it can refetch or say what it couldn't read.
 */
export function truncatePageContent(content: string, limit: number): string {
  if (content.length <= limit) {
    return content;
  }
  // Advice must be honorable from THIS layer: the runner truncates every
  // fetch regardless of query params, so never suggest ?full_text=true here
  // (that expands the note body at the Rails layer — making the page bigger).
  // A narrower page is the one thing that reliably fits under the cap.
  return `${content.slice(0, limit)}\n\n[page truncated: showing ${limit} of ${content.length} characters. ` +
    `Fetch a more specific path — e.g. a single comment's page — to read content that was cut off.]`;
}

/**
 * Replace stale page-fetch tool results with a one-line stub, keeping the
 * most recent ones full.
 *
 * Every LLM call resends the whole message array, so without this each page
 * ever fetched is re-billed on every subsequent step. The agent's own
 * assistant turns (what it concluded from those pages) stay; if it needs a
 * stale page back, the stub says how. execute_action results are never
 * elided — they record what the agent did, which it must not lose.
 *
 * Pure: returns a new array, never mutates the input.
 */
export function elideStalePageContent(
  messages: readonly Message[],
  keepLast: number = ELIDE_KEEP_LAST,
): readonly Message[] {
  const pageToolCallsById = new Map<string, { name: string; descriptor: string }>();
  for (const message of messages) {
    for (const tc of message.tool_calls ?? []) {
      if (!PAGE_TOOLS.has(tc.function.name)) {
        continue;
      }
      pageToolCallsById.set(tc.id, {
        name: tc.function.name,
        descriptor: describeToolCall(tc),
      });
    }
  }

  const elidableIndexes: number[] = [];
  messages.forEach((message, i) => {
    if (
      message.role === "tool" &&
      message.tool_call_id !== undefined &&
      pageToolCallsById.has(message.tool_call_id) &&
      (message.content?.length ?? 0) > ELIDE_MIN_LENGTH
    ) {
      elidableIndexes.push(i);
    }
  });

  const toElide = new Set(elidableIndexes.slice(0, Math.max(0, elidableIndexes.length - keepLast)));
  if (toElide.size === 0) {
    return messages;
  }

  return messages.map((message, i): Message => {
    if (!toElide.has(i)) {
      return message;
    }
    const call = pageToolCallsById.get(message.tool_call_id ?? "");
    return {
      ...message,
      content: `[earlier ${call?.name ?? "page"} result for ${call?.descriptor ?? "a page"} elided to save context — fetch it again if you need it]`,
    };
  });
}

/** Human-readable target of a page tool call, best-effort from its arguments. */
function describeToolCall(tc: ToolCall): string {
  try {
    const args = JSON.parse(tc.function.arguments) as Record<string, unknown>;
    const target = args["path"] ?? args["query"] ?? args["topic"];
    if (typeof target === "string" && target !== "") {
      return target;
    }
  } catch {
    // fall through to the generic descriptor
  }
  return "a page";
}
