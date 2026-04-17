import { describe, it, expect } from "vitest";
import {
  navigateStep,
  executeStep,
  thinkStep,
  errorStep,
  securityWarningStep,
  doneStep,
  scratchpadUpdateStep,
  scratchpadUpdateFailedStep,
} from "../../src/core/StepBuilder.js";

describe("StepBuilder", () => {
  const timestamp = new Date("2026-04-13T10:00:00Z");

  describe("navigateStep", () => {
    it("builds navigate step with rich detail matching Ruby", () => {
      const step = navigateStep({
        path: "/notifications",
        resolvedPath: "/notifications",
        contentPreview: "# Notifications\n\nYou have 3 unread.",
        availableActions: ["mark_read", "dismiss"],
        error: null,
      }, timestamp);

      expect(step.type).toBe("navigate");
      expect(step.detail).toEqual({
        path: "/notifications",
        resolved_path: "/notifications",
        content_preview: "# Notifications\n\nYou have 3 unread.",
        available_actions: ["mark_read", "dismiss"],
        error: null,
      });
      expect(step.timestamp).toBe("2026-04-13T10:00:00.000Z");
    });

    it("includes error when navigation fails", () => {
      const step = navigateStep({
        path: "/bad-path",
        resolvedPath: "/bad-path",
        contentPreview: "",
        availableActions: [],
        error: "Not found",
      }, timestamp);

      expect(step.detail["error"]).toBe("Not found");
    });
  });

  describe("executeStep", () => {
    it("builds execute step with rich detail matching Ruby", () => {
      const step = executeStep({
        action: "create_note",
        params: { body: "Hello" },
        success: true,
        contentPreview: "Note created successfully",
        error: null,
      }, timestamp);

      expect(step.type).toBe("execute");
      expect(step.detail).toEqual({
        action: "create_note",
        params: { body: "Hello" },
        success: true,
        content_preview: "Note created successfully",
        error: null,
      });
    });

    it("builds failed execute step", () => {
      const step = executeStep({
        action: "delete_note",
        params: {},
        success: false,
        contentPreview: null,
        error: "Invalid action 'delete_note'. Available actions: create_note, vote",
      }, timestamp);

      expect(step.detail["success"]).toBe(false);
      expect(step.detail["content_preview"]).toBeNull();
      expect(step.detail["error"]).toContain("Invalid action");
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
