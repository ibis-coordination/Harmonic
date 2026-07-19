import { describe, it, expect } from "vitest";
import {
  buildInitialMessages,
  buildToolResultMessages,
  systemMessage,
  userMessage,
  assistantMessage,
  truncatePageContent,
  elideStalePageContent,
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

describe("truncatePageContent", () => {
  it("returns content under the limit unchanged", () => {
    expect(truncatePageContent("short content", 4000)).toBe("short content");
  });

  it("returns content exactly at the limit unchanged", () => {
    const content = "a".repeat(4000);
    expect(truncatePageContent(content, 4000)).toBe(content);
  });

  it("truncates long content with a visible, actionable marker", () => {
    const content = "a".repeat(5000);
    const result = truncatePageContent(content, 4000);
    expect(result.startsWith("a".repeat(4000))).toBe(true);
    expect(result).toContain("[page truncated");
    expect(result).toContain("4000");
    expect(result).toContain("5000");
    expect(result).toContain("more specific path");
    // The runner truncates regardless of query params, so it must not
    // suggest ?full_text=true — that's the Rails layer's advice, and it
    // makes the page BIGGER (circular for anything thread-shaped)
    expect(result).not.toContain("full_text");
  });
});

describe("elideStalePageContent", () => {
  const bigPage = (label: string) => `# Page ${label}\n${"x".repeat(2000)}`;

  function pageFetchExchange(path: string, id: string, content: string) {
    return [
      assistantMessage(undefined, [
        { id, type: "function" as const, function: { name: "fetch_page", arguments: JSON.stringify({ path }) } },
      ]),
      { role: "tool" as const, content, tool_call_id: id },
    ];
  }

  function actionExchange(action: string, id: string, content: string) {
    return [
      assistantMessage(undefined, [
        { id, type: "function" as const, function: { name: "execute_action", arguments: JSON.stringify({ path: "/", action, params: {} }) } },
      ]),
      { role: "tool" as const, content, tool_call_id: id },
    ];
  }

  it("elides all but the most recent page fetches", () => {
    const messages = [
      systemMessage("sys"),
      userMessage("task"),
      ...pageFetchExchange("/n/aaa", "call_a", bigPage("A")),
      ...pageFetchExchange("/n/bbb", "call_b", bigPage("B")),
      ...pageFetchExchange("/n/ccc", "call_c", bigPage("C")),
    ];

    const result = elideStalePageContent(messages);

    const toolResults = result.filter((m) => m.role === "tool");
    expect(toolResults[0]?.content).toContain("elided");
    expect(toolResults[0]?.content).toContain("/n/aaa");
    expect(toolResults[0]?.content?.length).toBeLessThan(300);
    expect(toolResults[1]?.content).toBe(bigPage("B"));
    expect(toolResults[2]?.content).toBe(bigPage("C"));
  });

  it("never elides execute_action results", () => {
    const messages = [
      systemMessage("sys"),
      userMessage("task"),
      ...actionExchange("create_note", "call_1", `created note\n${"y".repeat(2000)}`),
      ...pageFetchExchange("/n/aaa", "call_a", bigPage("A")),
      ...pageFetchExchange("/n/bbb", "call_b", bigPage("B")),
      ...pageFetchExchange("/n/ccc", "call_c", bigPage("C")),
    ];

    const result = elideStalePageContent(messages);

    const toolResults = result.filter((m) => m.role === "tool");
    expect(toolResults[0]?.content).toContain("y".repeat(2000));
  });

  it("leaves small stale page results alone — eliding gains nothing", () => {
    const messages = [
      systemMessage("sys"),
      userMessage("task"),
      ...pageFetchExchange("/n/aaa", "call_a", "tiny page"),
      ...pageFetchExchange("/n/bbb", "call_b", bigPage("B")),
      ...pageFetchExchange("/n/ccc", "call_c", bigPage("C")),
    ];

    const result = elideStalePageContent(messages);

    const toolResults = result.filter((m) => m.role === "tool");
    expect(toolResults[0]?.content).toBe("tiny page");
  });

  it("does not mutate the input messages", () => {
    const messages = [
      systemMessage("sys"),
      userMessage("task"),
      ...pageFetchExchange("/n/aaa", "call_a", bigPage("A")),
      ...pageFetchExchange("/n/bbb", "call_b", bigPage("B")),
      ...pageFetchExchange("/n/ccc", "call_c", bigPage("C")),
    ];
    const originalContents = messages.map((m) => m.content);

    elideStalePageContent(messages);

    expect(messages.map((m) => m.content)).toEqual(originalContents);
  });

  it("elides page results with unparseable tool arguments without throwing", () => {
    const messages = [
      systemMessage("sys"),
      userMessage("task"),
      assistantMessage(undefined, [
        { id: "call_a", type: "function" as const, function: { name: "fetch_page", arguments: "not json" } },
      ]),
      { role: "tool" as const, content: bigPage("A"), tool_call_id: "call_a" },
      ...pageFetchExchange("/n/bbb", "call_b", bigPage("B")),
      ...pageFetchExchange("/n/ccc", "call_c", bigPage("C")),
    ];

    const result = elideStalePageContent(messages);

    const toolResults = result.filter((m) => m.role === "tool");
    expect(toolResults[0]?.content).toContain("elided");
  });

  it("keeps everything when there are only two page fetches", () => {
    const messages = [
      systemMessage("sys"),
      userMessage("task"),
      ...pageFetchExchange("/n/aaa", "call_a", bigPage("A")),
      ...pageFetchExchange("/n/bbb", "call_b", bigPage("B")),
    ];

    const result = elideStalePageContent(messages);

    const toolResults = result.filter((m) => m.role === "tool");
    expect(toolResults[0]?.content).toBe(bigPage("A"));
    expect(toolResults[1]?.content).toBe(bigPage("B"));
  });
});
