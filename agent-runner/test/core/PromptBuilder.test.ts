import { describe, it, expect } from "vitest";
import {
  buildInitialMessages,
  buildToolResultMessages,
  systemMessage,
  userMessage,
  assistantMessage,
} from "../../src/core/PromptBuilder.js";
import type { TaskPayload } from "../../src/core/PromptBuilder.js";

describe("buildInitialMessages", () => {
  const task: TaskPayload = {
    taskRunId: "run-1",
    encryptedToken: "dGVzdC1lbmNyeXB0ZWQ=",
    task: "Check notifications and respond",
    maxSteps: 30,
    model: undefined,
    agentId: "agent-1",
    tenantSubdomain: "test",
    stripeCustomerStripeId: undefined,
  };

  it("builds system + user messages", () => {
    const messages = buildInitialMessages(task, "I am Agent Smith", undefined);
    expect(messages.length).toBe(2);
    expect(messages[0]?.role).toBe("system");
    expect(messages[1]?.role).toBe("user");
    expect(messages[1]?.content).toBe("Check notifications and respond");
  });

  it("includes identity content in system prompt", () => {
    const messages = buildInitialMessages(task, "I am Agent Smith", undefined);
    expect(messages[0]?.content).toContain("Agent Smith");
  });

  it("includes scratchpad when provided", () => {
    const messages = buildInitialMessages(task, "Identity", "Previous context here");
    expect(messages[0]?.content).toContain("Previous context here");
    expect(messages[0]?.content).toContain("Scratchpad");
  });
});

describe("buildToolResultMessages", () => {
  it("builds tool messages from results", () => {
    const toolCalls = [
      { id: "call_1", type: "function" as const, function: { name: "navigate", arguments: '{"path":"/"}' } },
      { id: "call_2", type: "function" as const, function: { name: "execute_action", arguments: '{}' } },
    ];
    const results = ["Page content", "Action result"];

    const messages = buildToolResultMessages(toolCalls, results);
    expect(messages.length).toBe(2);
    expect(messages[0]?.role).toBe("tool");
    expect(messages[0]?.tool_call_id).toBe("call_1");
    expect(messages[0]?.content).toBe("Page content");
    expect(messages[1]?.tool_call_id).toBe("call_2");
  });
});

describe("message helpers", () => {
  it("creates system message", () => {
    const msg = systemMessage("System prompt");
    expect(msg.role).toBe("system");
    expect(msg.content).toBe("System prompt");
  });

  it("creates user message", () => {
    const msg = userMessage("Hello");
    expect(msg.role).toBe("user");
    expect(msg.content).toBe("Hello");
  });

  it("creates assistant message with tool calls", () => {
    const toolCalls = [{ id: "1", type: "function" as const, function: { name: "navigate", arguments: "{}" } }];
    const msg = assistantMessage("thinking", toolCalls);
    expect(msg.role).toBe("assistant");
    expect(msg.tool_calls).toBeDefined();
    expect(msg.tool_calls?.length).toBe(1);
  });

  it("creates assistant message without tool calls", () => {
    const msg = assistantMessage("Just text", undefined);
    expect(msg.role).toBe("assistant");
    expect(msg.tool_calls).toBeUndefined();
  });
});
