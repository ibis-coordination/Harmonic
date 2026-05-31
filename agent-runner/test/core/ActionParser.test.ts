import { describe, it, expect } from "vitest";
import { parseToolCalls } from "../../src/core/ActionParser.js";

describe("parseToolCalls", () => {
  it("returns done when no tool calls", () => {
    const result = parseToolCalls(undefined, "I'm done now");
    expect(result).toEqual([{ type: "done", content: "I'm done now" }]);
  });

  it("returns done for empty tool calls", () => {
    const result = parseToolCalls([], "Finished");
    expect(result).toEqual([{ type: "done", content: "Finished" }]);
  });

  it("parses fetch_page tool call", () => {
    const result = parseToolCalls(
      [{
        id: "call_1",
        type: "function",
        function: {
          name: "fetch_page",
          arguments: '{"path": "/notifications"}',
        },
      }],
      undefined,
    );
    expect(result).toEqual([{ type: "fetch_page", path: "/notifications" }]);
  });

  it("parses execute_action tool call with path", () => {
    const result = parseToolCalls(
      [{
        id: "call_2",
        type: "function",
        function: {
          name: "execute_action",
          arguments: '{"path": "/collectives/team/note", "action": "create_note", "params": {"body": "Hello"}}',
        },
      }],
      undefined,
    );
    expect(result).toEqual([{
      type: "execute_action",
      path: "/collectives/team/note",
      action: "create_note",
      params: { body: "Hello" },
    }]);
  });

  it("handles execute_action without params", () => {
    const result = parseToolCalls(
      [{
        id: "call_3",
        type: "function",
        function: {
          name: "execute_action",
          arguments: '{"path": "/n/abc", "action": "confirm_read"}',
        },
      }],
      undefined,
    );
    expect(result).toEqual([{
      type: "execute_action",
      path: "/n/abc",
      action: "confirm_read",
      params: undefined,
    }]);
  });

  it("returns error for execute_action without path", () => {
    const result = parseToolCalls(
      [{
        id: "call_x",
        type: "function",
        function: {
          name: "execute_action",
          arguments: '{"action": "create_note"}',
        },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
    if (result[0]?.type === "error") {
      expect(result[0].message).toContain("path");
    }
  });

  it("returns error for execute_action with empty path", () => {
    const result = parseToolCalls(
      [{
        id: "call_y",
        type: "function",
        function: {
          name: "execute_action",
          arguments: '{"path": "", "action": "create_note"}',
        },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
  });

  it("returns error for invalid JSON arguments", () => {
    const result = parseToolCalls(
      [{
        id: "call_4",
        type: "function",
        function: { name: "fetch_page", arguments: "not json" },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
  });

  it("returns error for unknown tool", () => {
    const result = parseToolCalls(
      [{
        id: "call_5",
        type: "function",
        function: { name: "unknown_tool", arguments: "{}" },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
    if (result[0]?.type === "error") {
      expect(result[0].message).toContain("Unknown tool");
    }
  });

  it("returns error for fetch_page without path", () => {
    const result = parseToolCalls(
      [{
        id: "call_6",
        type: "function",
        function: { name: "fetch_page", arguments: "{}" },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
  });

  it("parses search tool call", () => {
    const result = parseToolCalls(
      [{
        id: "call_7",
        type: "function",
        function: {
          name: "search",
          arguments: '{"query": "type:note status:open"}',
        },
      }],
      undefined,
    );
    expect(result).toEqual([{ type: "search", query: "type:note status:open" }]);
  });

  it("returns error for search without query", () => {
    const result = parseToolCalls(
      [{
        id: "call_8",
        type: "function",
        function: { name: "search", arguments: "{}" },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
    if (result[0]?.type === "error") {
      expect(result[0].message).toContain("search");
      expect(result[0].message).toContain("query");
    }
  });

  it("returns error for search with empty query", () => {
    const result = parseToolCalls(
      [{
        id: "call_9",
        type: "function",
        function: { name: "search", arguments: '{"query": ""}' },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
  });

  it("parses get_help tool call", () => {
    const result = parseToolCalls(
      [{
        id: "call_10",
        type: "function",
        function: {
          name: "get_help",
          arguments: '{"topic": "decisions"}',
        },
      }],
      undefined,
    );
    expect(result).toEqual([{ type: "get_help", topic: "decisions" }]);
  });

  it("returns error for get_help without topic", () => {
    const result = parseToolCalls(
      [{
        id: "call_11",
        type: "function",
        function: { name: "get_help", arguments: "{}" },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
    if (result[0]?.type === "error") {
      expect(result[0].message).toContain("get_help");
      expect(result[0].message).toContain("topic");
    }
  });

  it("returns error for get_help with empty topic", () => {
    const result = parseToolCalls(
      [{
        id: "call_12",
        type: "function",
        function: { name: "get_help", arguments: '{"topic": ""}' },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
  });
});
