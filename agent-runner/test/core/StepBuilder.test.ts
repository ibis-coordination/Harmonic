import { describe, it, expect } from "vitest";
import {
  fetchPageStep,
  executeActionStep,
  thinkStep,
  errorStep,
  securityWarningStep,
  doneStep,
  scratchpadUpdateStep,
  scratchpadUpdateFailedStep,
} from "../../src/core/StepBuilder.js";

describe("StepBuilder", () => {
  const timestamp = new Date("2026-04-13T10:00:00Z");

  describe("fetchPageStep", () => {
    it("builds fetch_page step with rich detail and surfaces mcp_tool_call_log_id", () => {
      const step = fetchPageStep({
        path: "/notifications",
        resolvedPath: "/notifications",
        contentPreview: "# Notifications\n\nYou have 3 unread.",
        availableActions: ["mark_read", "dismiss"],
        error: null,
        mcp_tool_call_log_id: "log-uuid-1",
      }, timestamp);

      expect(step.type).toBe("fetch_page");
      expect(step.detail).toEqual({
        path: "/notifications",
        resolved_path: "/notifications",
        content_preview: "# Notifications\n\nYou have 3 unread.",
        available_actions: ["mark_read", "dismiss"],
        error: null,
      });
      expect(step.timestamp).toBe("2026-04-13T10:00:00.000Z");
      expect(step.mcp_tool_call_log_id).toBe("log-uuid-1");
    });

    it("includes error when fetch fails and leaves mcp_tool_call_log_id null", () => {
      const step = fetchPageStep({
        path: "/bad-path",
        resolvedPath: "/bad-path",
        contentPreview: "",
        availableActions: [],
        error: "Not found",
        mcp_tool_call_log_id: null,
      }, timestamp);

      expect(step.detail["error"]).toBe("Not found");
      expect(step.mcp_tool_call_log_id).toBeNull();
    });
  });

  describe("executeActionStep", () => {
    it("builds execute_action step with rich detail and surfaces mcp_tool_call_log_id", () => {
      const step = executeActionStep({
        action: "create_note",
        params: { body: "Hello" },
        success: true,
        contentPreview: "Note created successfully",
        error: null,
        mcp_tool_call_log_id: "log-uuid-2",
      }, timestamp);

      expect(step.type).toBe("execute_action");
      expect(step.detail).toEqual({
        action: "create_note",
        params: { body: "Hello" },
        success: true,
        content_preview: "Note created successfully",
        error: null,
      });
      expect(step.mcp_tool_call_log_id).toBe("log-uuid-2");
    });

    it("builds failed execute_action step", () => {
      const step = executeActionStep({
        action: "delete_note",
        params: {},
        success: false,
        contentPreview: null,
        error: "Invalid action 'delete_note'. Available actions: create_note, vote",
        mcp_tool_call_log_id: null,
      }, timestamp);

      expect(step.detail["success"]).toBe(false);
      expect(step.detail["content_preview"]).toBeNull();
      expect(step.detail["error"]).toContain("Invalid action");
      expect(step.mcp_tool_call_log_id).toBeNull();
    });
  });

  describe("thinkStep", () => {
    it("builds think step with prompt and response matching Ruby", () => {
      const step = thinkStep({
        stepNumber: 2,
        promptPreview: "## Current State\n**Step**: 3\n...",
        responsePreview: '{"type": "navigate", "path": "/notifications"}',
        llmError: null,
      }, timestamp);

      expect(step.type).toBe("think");
      expect(step.detail).toEqual({
        step_number: 2,
        prompt_preview: "## Current State\n**Step**: 3\n...",
        response_preview: '{"type": "navigate", "path": "/notifications"}',
      });
    });

    it("includes llm_error when present", () => {
      const step = thinkStep({
        stepNumber: 0,
        promptPreview: "prompt",
        responsePreview: "",
        llmError: "Connection timeout",
      }, timestamp);

      expect(step.detail["llm_error"]).toBe("Connection timeout");
    });

    it("omits llm_error when null", () => {
      const step = thinkStep({
        stepNumber: 0,
        promptPreview: "prompt",
        responsePreview: "response",
        llmError: null,
      }, timestamp);

      expect(step.detail).not.toHaveProperty("llm_error");
    });

    it("includes tool_calls when present", () => {
      const step = thinkStep({
        stepNumber: 1,
        promptPreview: "prompt",
        responsePreview: "",
        llmError: null,
        toolCalls: [
          { name: "navigate", arguments: '{"path":"/notifications"}' },
          { name: "execute_action", arguments: '{"action":"create_note","params":{"body":"hi"}}' },
        ],
      }, timestamp);

      expect(step.detail["tool_calls"]).toEqual([
        { name: "navigate", arguments: '{"path":"/notifications"}' },
        { name: "execute_action", arguments: '{"action":"create_note","params":{"body":"hi"}}' },
      ]);
    });

    it("omits tool_calls when none were emitted", () => {
      const step = thinkStep({
        stepNumber: 1,
        promptPreview: "prompt",
        responsePreview: "All done",
        llmError: null,
        toolCalls: [],
      }, timestamp);

      expect(step.detail).not.toHaveProperty("tool_calls");
    });

    it("omits tool_calls when undefined", () => {
      const step = thinkStep({
        stepNumber: 0,
        promptPreview: "prompt",
        responsePreview: "response",
        llmError: null,
      }, timestamp);

      expect(step.detail).not.toHaveProperty("tool_calls");
    });

    it("includes reasoning when present", () => {
      const step = thinkStep({
        stepNumber: 2,
        promptPreview: "prompt",
        responsePreview: "",
        llmError: null,
        reasoning: "The user asked about notifications, so I should navigate there first.",
      }, timestamp);

      expect(step.detail["reasoning"]).toBe(
        "The user asked about notifications, so I should navigate there first.",
      );
    });

    it("omits reasoning when undefined or empty", () => {
      const stepUndefined = thinkStep({
        stepNumber: 0,
        promptPreview: "prompt",
        responsePreview: "response",
        llmError: null,
      }, timestamp);
      const stepEmpty = thinkStep({
        stepNumber: 0,
        promptPreview: "prompt",
        responsePreview: "response",
        llmError: null,
        reasoning: "",
      }, timestamp);

      expect(stepUndefined.detail).not.toHaveProperty("reasoning");
      expect(stepEmpty.detail).not.toHaveProperty("reasoning");
    });
  });

  describe("errorStep", () => {
    it("builds error step with message", () => {
      const step = errorStep({ message: "Something went wrong" }, timestamp);
      expect(step.type).toBe("error");
      expect(step.detail).toEqual({ message: "Something went wrong" });
    });
  });

  describe("securityWarningStep", () => {
    it("builds security_warning step matching Ruby structure", () => {
      const step = securityWarningStep({
        reasons: ["canary_token_detected", "identity_prompt_similarity"],
        stepNumber: 3,
      }, timestamp);

      expect(step.type).toBe("security_warning");
      expect(step.detail).toEqual({
        type: "identity_prompt_leakage",
        reasons: ["canary_token_detected", "identity_prompt_similarity"],
        step_number: 3,
      });
    });
  });

  describe("doneStep", () => {
    it("builds done step with message", () => {
      const step = doneStep({ message: "Task completed" }, timestamp);
      expect(step.type).toBe("done");
      expect(step.detail).toEqual({ message: "Task completed" });
    });
  });

  describe("scratchpadUpdateStep", () => {
    it("builds scratchpad_update step", () => {
      const step = scratchpadUpdateStep({ content: "Remember: user likes bullet points" }, timestamp);
      expect(step.type).toBe("scratchpad_update");
      expect(step.detail).toEqual({ content: "Remember: user likes bullet points" });
    });
  });

  describe("scratchpadUpdateFailedStep", () => {
    it("builds scratchpad_update_failed step", () => {
      const step = scratchpadUpdateFailedStep({ error: "JSON parse error" }, timestamp);
      expect(step.type).toBe("scratchpad_update_failed");
      expect(step.detail).toEqual({ error: "JSON parse error" });
    });
  });
});
