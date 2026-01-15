import { describe, it, expect } from "vitest";
import {
  extractToolUses,
  extractTextContent,
  type AiResponse,
  type ContentBlock,
} from "./AiProvider.js";

describe("AiProvider helpers", () => {
  describe("extractToolUses", () => {
    it("should extract tool uses from response", () => {
      const response: AiResponse = {
        content: [
          { type: "text", text: "I'll navigate to the page" },
          {
            type: "tool_use",
            id: "tool-1",
            name: "navigate",
            input: { path: "/studios/test" },
          },
        ],
        stopReason: "tool_use",
        usage: { inputTokens: 100, outputTokens: 50 },
      };

      const toolUses = extractToolUses(response);

      expect(toolUses).toHaveLength(1);
      expect(toolUses[0]).toEqual({
        id: "tool-1",
        name: "navigate",
        input: { path: "/studios/test" },
      });
    });

    it("should extract multiple tool uses", () => {
      const response: AiResponse = {
        content: [
          {
            type: "tool_use",
            id: "tool-1",
            name: "navigate",
            input: { path: "/a" },
          },
          {
            type: "tool_use",
            id: "tool-2",
            name: "execute_action",
            input: { action: "confirm_read" },
          },
        ],
        stopReason: "tool_use",
        usage: { inputTokens: 100, outputTokens: 50 },
      };

      const toolUses = extractToolUses(response);

      expect(toolUses).toHaveLength(2);
      expect(toolUses[0]?.name).toBe("navigate");
      expect(toolUses[1]?.name).toBe("execute_action");
    });

    it("should return empty array when no tool uses", () => {
      const response: AiResponse = {
        content: [{ type: "text", text: "Just some text" }],
        stopReason: "end_turn",
        usage: { inputTokens: 100, outputTokens: 50 },
      };

      const toolUses = extractToolUses(response);

      expect(toolUses).toHaveLength(0);
    });

    it("should filter out incomplete tool uses", () => {
      const response: AiResponse = {
        content: [
          { type: "tool_use" } as ContentBlock, // missing required fields
          {
            type: "tool_use",
            id: "tool-1",
            name: "navigate",
            input: { path: "/test" },
          },
        ],
        stopReason: "tool_use",
        usage: { inputTokens: 100, outputTokens: 50 },
      };

      const toolUses = extractToolUses(response);

      expect(toolUses).toHaveLength(1);
    });
  });

  describe("extractTextContent", () => {
    it("should extract text from response", () => {
      const response: AiResponse = {
        content: [
          { type: "text", text: "Hello " },
          { type: "text", text: "World" },
        ],
        stopReason: "end_turn",
        usage: { inputTokens: 100, outputTokens: 50 },
      };

      const text = extractTextContent(response);

      expect(text).toBe("Hello \nWorld");
    });

    it("should filter out non-text content", () => {
      const response: AiResponse = {
        content: [
          { type: "text", text: "I'll help" },
          {
            type: "tool_use",
            id: "1",
            name: "navigate",
            input: { path: "/" },
          },
        ],
        stopReason: "tool_use",
        usage: { inputTokens: 100, outputTokens: 50 },
      };

      const text = extractTextContent(response);

      expect(text).toBe("I'll help");
    });

    it("should return empty string when no text content", () => {
      const response: AiResponse = {
        content: [
          {
            type: "tool_use",
            id: "1",
            name: "navigate",
            input: { path: "/" },
          },
        ],
        stopReason: "tool_use",
        usage: { inputTokens: 100, outputTokens: 50 },
      };

      const text = extractTextContent(response);

      expect(text).toBe("");
    });
  });
});
