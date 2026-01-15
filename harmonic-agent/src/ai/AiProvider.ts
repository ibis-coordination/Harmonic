import { Context, Effect } from "effect";
import { AiProviderError } from "../errors/Errors.js";

export interface Message {
  role: "user" | "assistant";
  content: string | ContentBlock[];
}

export interface ContentBlock {
  type: "text" | "tool_use" | "tool_result";
  text?: string;
  id?: string;
  name?: string;
  input?: Record<string, unknown>;
  tool_use_id?: string;
  content?: string;
  is_error?: boolean;
}

export interface Tool {
  name: string;
  description: string;
  input_schema: {
    type: "object";
    properties: Record<string, unknown>;
    required?: string[];
  };
}

export interface ToolUse {
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface AiResponse {
  content: ContentBlock[];
  stopReason: "end_turn" | "tool_use" | "max_tokens" | "stop_sequence";
  usage: {
    inputTokens: number;
    outputTokens: number;
  };
}

export class AiProvider extends Context.Tag("AiProvider")<
  AiProvider,
  {
    readonly chat: (
      systemPrompt: string,
      messages: Message[],
      tools: Tool[]
    ) => Effect.Effect<AiResponse, AiProviderError>;
  }
>() {}

export function extractToolUses(response: AiResponse): ToolUse[] {
  return response.content
    .filter((block): block is ContentBlock & { type: "tool_use"; id: string; name: string; input: Record<string, unknown> } =>
      block.type === "tool_use" && !!block.id && !!block.name && !!block.input
    )
    .map((block) => ({
      id: block.id,
      name: block.name,
      input: block.input,
    }));
}

export function extractTextContent(response: AiResponse): string {
  return response.content
    .filter((block): block is ContentBlock & { type: "text"; text: string } =>
      block.type === "text" && !!block.text
    )
    .map((block) => block.text)
    .join("\n");
}
