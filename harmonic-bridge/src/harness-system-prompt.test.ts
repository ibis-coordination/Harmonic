import { test } from "node:test";
import assert from "node:assert/strict";
import { buildSystemPrompt } from "./harness-system-prompt.js";

test("harness-system-prompt: embeds the harness-specific tools paragraph verbatim", () => {
  const prompt = buildSystemPrompt({ toolsParagraph: "You have Frobnicate and Widget available." });
  assert.match(prompt, /You have Frobnicate and Widget available\./);
});

test("harness-system-prompt: carries the framing every harness needs", () => {
  const prompt = buildSystemPrompt({ toolsParagraph: "tools go here" });

  // stdout is a wall; execute_action is the only way to be seen.
  assert.match(prompt, /stdout is NOT visible/);
  assert.match(prompt, /execute_action/);
  // The wake procedure and the payload shape.
  assert.match(prompt, /fetch_page on \/whoami/);
  assert.match(prompt, /notifications\.delivered/);
  assert.match(prompt, /harmonic\.webhook\.test/);
  // Don't reply to yourself.
  assert.match(prompt, /actor\.id is your own/);
  // The resource URI is not a fetch_page path.
  assert.doesNotMatch(prompt, /harmonic:\/\/context/);
});

test("harness-system-prompt: is a complete file body", () => {
  const prompt = buildSystemPrompt({ toolsParagraph: "tools go here" });
  assert.ok(prompt.endsWith("\n"), "must end with a trailing newline");
  assert.doesNotMatch(prompt, /\n\n\n/, "must not leave a blank-line gap around the tools paragraph");
});
