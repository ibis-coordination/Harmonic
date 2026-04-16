import { describe, it, expect } from "vitest";
import { parseToolCalls, validateAction } from "../../src/core/ActionParser.js";

describe("parseToolCalls", () => {
  it("returns done when no tool calls", () => {
    const result = parseToolCalls(undefined, "I'm done now");
    expect(result).toEqual([{ type: "done", content: "I'm done now" }]);
  });

  it("returns done for empty tool calls", () => {
    const result = parseToolCalls([], "Finished");
    expect(result).toEqual([{ type: "done", content: "Finished" }]);
  });

  it("parses navigate tool call", () => {
    const result = parseToolCalls(
      [{
        id: "call_1",
        type: "function",
        function: {
          name: "navigate",
          arguments: '{"path": "/notifications"}',
        },
      }],
      undefined,
    );
    expect(result).toEqual([{ type: "navigate", path: "/notifications" }]);
  });

  it("parses execute_action tool call", () => {
    const result = parseToolCalls(
      [{
        id: "call_2",
        type: "function",
        function: {
          name: "execute_action",
          arguments: '{"action": "create_note", "params": {"body": "Hello"}}',
        },
      }],
      undefined,
    );
    expect(result).toEqual([{
      type: "execute_action",
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
          arguments: '{"action": "confirm_read"}',
        },
      }],
      undefined,
    );
    expect(result).toEqual([{
      type: "execute_action",
      action: "confirm_read",
      params: undefined,
    }]);
  });

  it("returns error for invalid JSON arguments", () => {
    const result = parseToolCalls(
      [{
        id: "call_4",
        type: "function",
        function: { name: "navigate", arguments: "not json" },
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

  it("returns error for navigate without path", () => {
    const result = parseToolCalls(
      [{
        id: "call_6",
        type: "function",
        function: { name: "navigate", arguments: "{}" },
      }],
      undefined,
    );
    expect(result[0]?.type).toBe("error");
  });
});

describe("validateAction", () => {
  it("validates available action", () => {
    const result = validateAction("create_note", ["create_note", "vote"]);
    expect(result.valid).toBe(true);
  });

  it("rejects unavailable action", () => {
    const result = validateAction("delete_everything", ["create_note", "vote"]);
    expect(result.valid).toBe(false);
    expect(result.error).toContain("not available");
  });
});
