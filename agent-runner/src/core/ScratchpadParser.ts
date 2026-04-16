/**
 * Scratchpad parsing and sanitization — pure functions.
 * Ported from AgentNavigator scratchpad update logic (lines 290-349).
 * Must match Ruby implementation exactly.
 */

const MAX_SCRATCHPAD_LENGTH = 10_000;
// Matches Ruby: str.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
// Removes control chars except tab (0x09), newline (0x0A), carriage return (0x0D)
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g;

export interface ScratchpadParseResult {
  readonly success: true;
  readonly scratchpad: string;
}

export interface ScratchpadParseFailure {
  readonly success: false;
  readonly error: string;
}

export type ParseResult = ScratchpadParseResult | ScratchpadParseFailure;

/**
 * Parse LLM response into a scratchpad update.
 * Matches Ruby parsing logic:
 * 1. Try ```json ... ``` regex, fallback to { ... } regex
 * 2. Sanitize JSON string (remove control chars)
 * 3. Parse JSON
 * 4. Check if parsed["scratchpad"] is present (non-null, non-empty)
 * 5. Sanitize and truncate content
 */
export function parseScratchpadResponse(response: string): ParseResult {
  const trimmed = response.trim();

  // Match Ruby regex: /```json\s*(.*?)\s*```/m || /\{.*\}/m
  const jsonContent = extractJsonFromResponse(trimmed);

  try {
    const sanitized = sanitizeJsonString(jsonContent);
    const parsed: unknown = JSON.parse(sanitized);
    if (typeof parsed !== "object" || parsed === null) {
      return { success: false, error: "Response is not a JSON object" };
    }
    const obj = parsed as Record<string, unknown>;
    const scratchpad = obj["scratchpad"];

    // Match Ruby: if parsed["scratchpad"].present? — null, undefined, and empty string are not "present"
    if (scratchpad === null || scratchpad === undefined) {
      return { success: false, error: "Scratchpad is null" };
    }
    const scratchpadStr = String(scratchpad);
    if (scratchpadStr === "") {
      return { success: false, error: "Scratchpad is empty" };
    }

    // Sanitize and truncate, matching Ruby: sanitize_json_string(parsed["scratchpad"].to_s)[0, 10_000]
    const content = sanitizeJsonString(scratchpadStr).slice(0, MAX_SCRATCHPAD_LENGTH);
    return { success: true, scratchpad: content };
  } catch {
    return { success: false, error: `Invalid JSON: ${jsonContent.slice(0, 100)}` };
  }
}

/**
 * Extract JSON from a response that may be wrapped in markdown code blocks.
 * Matches Ruby: result.content.match(/```json\s*(.*?)\s*```/m) || result.content.match(/\{.*\}/m)
 */
function extractJsonFromResponse(response: string): string {
  // Try ```json ... ``` first
  const codeBlockMatch = /```json\s*([\s\S]*?)\s*```/.exec(response);
  if (codeBlockMatch?.[1] !== undefined) {
    return codeBlockMatch[1];
  }
  // Fallback to { ... } (greedy, multiline)
  const jsonMatch = /\{[\s\S]*\}/.exec(response);
  if (jsonMatch?.[0] !== undefined) {
    return jsonMatch[0];
  }
  return response;
}

/**
 * Sanitize a string by removing invalid control characters.
 * Matches Ruby: str.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
 * Preserves: tab (0x09), newline (0x0A), carriage return (0x0D)
 */
export function sanitizeJsonString(content: string): string {
  return content.replace(CONTROL_CHARS, "");
}

/**
 * Sanitize scratchpad content: remove control characters and truncate.
 */
export function sanitizeScratchpad(content: string): string {
  return sanitizeJsonString(content).slice(0, MAX_SCRATCHPAD_LENGTH);
}

/**
 * Build the scratchpad update prompt.
 * Matches Ruby AgentNavigator.prompt_for_scratchpad_update exactly.
 */
export function buildScratchpadPrompt(
  task: string,
  outcome: string,
  finalMessage: string,
  stepsCount: number,
): string {
  return `## Task Complete

**Task**: ${task}
**Outcome**: ${outcome}
**Summary**: ${finalMessage}
**Steps taken**: ${stepsCount}

Please update your scratchpad with any context that would help your future self.
This might include:
- Key learnings from this task
- Important context discovered
- Work in progress or follow-ups needed
- User preferences observed

Respond with JSON:
\`\`\`json
{"scratchpad": "your updated scratchpad content"}
\`\`\`

If you have nothing to add, respond with:
\`\`\`json
{"scratchpad": null}
\`\`\``;
}
