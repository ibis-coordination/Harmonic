import { describe, it, expect } from "vitest";
import {
  parseScratchpadResponse,
  sanitizeScratchpad,
  sanitizeJsonString,
  buildScratchpadPrompt,
} from "../../src/core/ScratchpadParser.js";

describe("parseScratchpadResponse", () => {
  it("parses valid JSON response", () => {
    const result = parseScratchpadResponse('{"scratchpad": "Remember this"}');
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.scratchpad).toBe("Remember this");
    }
  });

  it("parses JSON from markdown code block", () => {
    const response = '```json\n{"scratchpad": "From code block"}\n```';
    const result = parseScratchpadResponse(response);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.scratchpad).toBe("From code block");
    }
  });

  it("fails for invalid JSON", () => {
    const result = parseScratchpadResponse("not json");
    expect(result.success).toBe(false);
  });

  it("fails for null scratchpad (matches Ruby present? check)", () => {
    const result = parseScratchpadResponse('{"scratchpad": null}');
    expect(result.success).toBe(false);
  });

  it("fails for empty scratchpad string", () => {
    const result = parseScratchpadResponse('{"scratchpad": ""}');
    expect(result.success).toBe(false);
  });

  it("fails for missing scratchpad field", () => {
    const result = parseScratchpadResponse('{"other": "value"}');
    expect(result.success).toBe(false);
  });

  it("sanitizes content in parsed response", () => {
    const result = parseScratchpadResponse('{"scratchpad": "clean\\u0000text"}');
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.scratchpad).toBe("cleantext");
    }
  });

  it("truncates to 10,000 characters", () => {
    const long = "a".repeat(15_000);
    const result = parseScratchpadResponse(`{"scratchpad": "${long}"}`);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.scratchpad.length).toBe(10_000);
    }
  });

  it("extracts JSON with fallback regex when no code block", () => {
    const response = 'Some text before {"scratchpad": "extracted"} some text after';
    const result = parseScratchpadResponse(response);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.scratchpad).toBe("extracted");
    }
  });
});

describe("sanitizeJsonString", () => {
  it("removes control characters", () => {
    expect(sanitizeJsonString("hello\x00world\x01!")).toBe("helloworld!");
  });

  it("preserves tabs, newlines, and carriage returns", () => {
    expect(sanitizeJsonString("line1\nline2\ttab\rreturn")).toBe("line1\nline2\ttab\rreturn");
  });

  it("removes 0x7F (DEL)", () => {
    expect(sanitizeJsonString("hello\x7Fworld")).toBe("helloworld");
  });
});

describe("sanitizeScratchpad", () => {
  it("removes control characters and truncates", () => {
    const long = "a".repeat(15_000);
    const result = sanitizeScratchpad(long);
    expect(result.length).toBe(10_000);
  });
});

describe("buildScratchpadPrompt", () => {
  it("matches Ruby prompt_for_scratchpad_update exactly", () => {
    const prompt = buildScratchpadPrompt(
      "Check notifications",
      "completed",
      "All done",
      5,
    );
    expect(prompt).toContain("## Task Complete");
    expect(prompt).toContain("**Task**: Check notifications");
    expect(prompt).toContain("**Outcome**: completed");
    expect(prompt).toContain("**Summary**: All done");
    expect(prompt).toContain("**Steps taken**: 5");
    expect(prompt).toContain("Update your scratchpad for your future self");
    expect(prompt).toContain("Active context");
    expect(prompt).toContain('{"scratchpad": "your updated scratchpad content"}');
    expect(prompt).toContain('{"scratchpad": null}');
  });

  it("uses the outcome string directly", () => {
    const prompt = buildScratchpadPrompt("Task", "incomplete - max steps reached", "Max steps", 30);
    expect(prompt).toContain("**Outcome**: incomplete - max steps reached");
  });
});
