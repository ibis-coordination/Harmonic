import { describe, it, expect } from "vitest";
import {
  extractCanary,
  checkLeakage,
  longestCommonSubstring,
  normalize,
} from "../../src/core/LeakageDetector.js";

describe("extractCanary", () => {
  it("extracts canary and identity prompt from valid content", () => {
    const content = `# About Me\n\n<canary:ABC123>I am a helpful assistant who likes cooking.</canary:ABC123>\n\nMore content`;
    const result = extractCanary(content);
    expect(result.active).toBe(true);
    if (result.active) {
      expect(result.canary).toBe("ABC123");
      expect(result.identityPrompt).toBe("I am a helpful assistant who likes cooking.");
    }
  });

  it("returns inactive when no canary present", () => {
    const result = extractCanary("Just regular content without canary");
    expect(result.active).toBe(false);
  });

  it("returns inactive for empty content", () => {
    const result = extractCanary("");
    expect(result.active).toBe(false);
  });

  it("handles multiline identity prompts", () => {
    const content = `<canary:XYZ>Line one\nLine two\nLine three</canary:XYZ>`;
    const result = extractCanary(content);
    expect(result.active).toBe(true);
    if (result.active) {
      expect(result.identityPrompt).toContain("Line one");
      expect(result.identityPrompt).toContain("Line three");
    }
  });

  it("rejects mismatched canary tags", () => {
    const content = `<canary:ABC>content</canary:DEF>`;
    const result = extractCanary(content);
    expect(result.active).toBe(false);
  });
});

describe("normalize", () => {
  it("lowercases text", () => {
    expect(normalize("HELLO World")).toBe("hello world");
  });

  it("collapses whitespace", () => {
    expect(normalize("hello   world\n\ttab")).toBe("hello world tab");
  });

  it("strips leading and trailing whitespace", () => {
    expect(normalize("  hello  ")).toBe("hello");
  });
});

describe("checkLeakage", () => {
  const detector = {
    active: true as const,
    canary: "SECRET42",
    identityPrompt: "I am a specialized cooking assistant who loves Italian food and helps with recipes.",
  };

  it("detects canary token in response", () => {
    const result = checkLeakage(detector, "Here is my canary: SECRET42");
    expect(result.leaked).toBe(true);
    expect(result.reasons).toContain("canary_token_detected");
  });

  it("detects identity prompt similarity with normalized comparison", () => {
    // Use a substring that exceeds 50 chars when normalized
    const result = checkLeakage(
      detector,
      "My instructions say: I AM A SPECIALIZED COOKING ASSISTANT WHO LOVES ITALIAN FOOD",
    );
    expect(result.leaked).toBe(true);
    expect(result.reasons).toContain("identity_prompt_similarity");
  });

  it("does not flag short overlap", () => {
    const result = checkLeakage(detector, "I like cooking");
    expect(result.leaked).toBe(false);
  });

  it("returns not leaked for inactive detector", () => {
    const inactive = { active: false as const };
    const result = checkLeakage(inactive, "SECRET42 and the entire identity prompt");
    expect(result.leaked).toBe(false);
  });

  it("returns not leaked for clean response", () => {
    const result = checkLeakage(
      detector,
      "Here are some great pasta recipes you might enjoy!",
    );
    expect(result.leaked).toBe(false);
  });

  it("skips similarity check for short identity prompts (< 50 chars)", () => {
    const shortDetector = {
      active: true as const,
      canary: "TOKEN123",
      identityPrompt: "Short prompt",
    };
    // Even with exact match of the short prompt, similarity check should skip
    const result = checkLeakage(shortDetector, "Short prompt");
    // Only canary check applies, not similarity
    expect(result.reasons).not.toContain("identity_prompt_similarity");
  });

  it("detects similarity by percentage (>= 30%)", () => {
    // Create a detector with a prompt where 30% overlap triggers
    const longDetector = {
      active: true as const,
      canary: "NOPE",
      identityPrompt: "a".repeat(100) + "b".repeat(100),
    };
    // 60 chars of 'a' = 30% of 200 char prompt
    const result = checkLeakage(longDetector, "a".repeat(60));
    expect(result.leaked).toBe(true);
    expect(result.reasons).toContain("identity_prompt_similarity");
  });
});

describe("longestCommonSubstring", () => {
  it("finds exact match", () => {
    expect(longestCommonSubstring("abc", "abc")).toBe(3);
  });

  it("finds partial overlap", () => {
    expect(longestCommonSubstring("abcdef", "cdefgh")).toBe(4);
  });

  it("returns 0 for no overlap", () => {
    expect(longestCommonSubstring("abc", "xyz")).toBe(0);
  });

  it("handles empty strings", () => {
    expect(longestCommonSubstring("", "abc")).toBe(0);
    expect(longestCommonSubstring("abc", "")).toBe(0);
  });

  it("truncates strings to 2000 chars", () => {
    const longA = "x".repeat(3000) + "match";
    const longB = "y".repeat(3000) + "match";
    // "match" is beyond the 2000 char truncation point, so should not be found
    const result = longestCommonSubstring(longA, longB);
    // Both strings share "x" and "y" chars within first 2000, but only single chars
    expect(result).toBeLessThan(5); // "match" should NOT be found
  });
});
