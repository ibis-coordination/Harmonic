/**
 * Identity prompt leakage detection — pure functions.
 * Ported from app/services/identity_prompt_leakage_detector.rb
 *
 * Must match Ruby implementation exactly:
 * - Canary regex: /<canary:([a-zA-Z0-9]+)>(.*?)<\/canary:\1>/m
 * - Normalization: lowercase, collapse whitespace, strip
 * - LCS truncation: 2000 chars max per string
 * - Thresholds: 50 chars absolute OR 30% of prompt length
 */

const CANARY_PATTERN = /<canary:([a-zA-Z0-9]+)>([\s\S]*?)<\/canary:\1>/;
const SIMILARITY_THRESHOLD_CHARS = 50;
const SIMILARITY_THRESHOLD_PERCENT = 0.3;
const MAX_LCS_LENGTH = 2000;

export interface CanaryInfo {
  readonly canary: string;
  readonly identityPrompt: string;
  readonly active: true;
}

export interface InactiveCanary {
  readonly active: false;
}

export type LeakageDetector = CanaryInfo | InactiveCanary;

export interface LeakageResult {
  readonly leaked: boolean;
  readonly reasons: readonly string[];
}

/**
 * Extract canary token and identity prompt from /whoami content.
 */
export function extractCanary(content: string): LeakageDetector {
  const match = CANARY_PATTERN.exec(content);
  if (match === null) {
    return { active: false };
  }
  const canary = match[1];
  const identityPrompt = match[2]?.trim();
  if (canary === undefined || identityPrompt === undefined || canary === "" || identityPrompt === "") {
    return { active: false };
  }
  return { canary, identityPrompt, active: true };
}

/**
 * Check an LLM response for identity prompt leakage.
 * Matches Ruby IdentityPromptLeakageDetector.check_leakage exactly.
 */
export function checkLeakage(detector: LeakageDetector, responseContent: string): LeakageResult {
  if (!detector.active) {
    return { leaked: false, reasons: [] };
  }

  const reasons: string[] = [];

  // Check 1: Canary token (exact substring match, same as Ruby)
  if (responseContent.includes(detector.canary)) {
    reasons.push("canary_token_detected");
  }

  // Check 2: Identity prompt similarity (uses normalization, same as Ruby)
  if (substantialOverlap(responseContent, detector.identityPrompt)) {
    reasons.push("identity_prompt_similarity");
  }

  return { leaked: reasons.length > 0, reasons };
}

/**
 * Matches Ruby IdentityPromptLeakageDetector.substantial_overlap?
 */
function substantialOverlap(output: string, identityPrompt: string): boolean {
  if (identityPrompt.length < SIMILARITY_THRESHOLD_CHARS) {
    return false;
  }

  const normalizedOutput = normalize(output);
  const normalizedPrompt = normalize(identityPrompt);

  const lcsLength = longestCommonSubstring(normalizedOutput, normalizedPrompt);

  if (lcsLength >= SIMILARITY_THRESHOLD_CHARS) return true;
  if (normalizedPrompt.length > 0 && lcsLength / normalizedPrompt.length >= SIMILARITY_THRESHOLD_PERCENT) return true;

  return false;
}

/**
 * Normalize text for comparison.
 * Matches Ruby: text.downcase.gsub(/\s+/, " ").strip
 */
export function normalize(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * Longest common substring length between two strings.
 * Matches Ruby: truncates both strings to 2000 chars before comparison.
 */
export function longestCommonSubstring(a: string, b: string): number {
  // Truncate to MAX_LCS_LENGTH, matching Ruby implementation
  const strA = a.length > MAX_LCS_LENGTH ? a.slice(0, MAX_LCS_LENGTH) : a;
  const strB = b.length > MAX_LCS_LENGTH ? b.slice(0, MAX_LCS_LENGTH) : b;

  if (strA.length === 0 || strB.length === 0) return 0;

  // Use the shorter string as rows for memory efficiency
  const [short, long] = strA.length <= strB.length ? [strA, strB] : [strB, strA];
  const prev = new Array<number>(short.length + 1).fill(0);
  const curr = new Array<number>(short.length + 1).fill(0);
  let max = 0;

  for (let i = 1; i <= long.length; i++) {
    for (let j = 1; j <= short.length; j++) {
      if (long[i - 1] === short[j - 1]) {
        curr[j] = (prev[j - 1] ?? 0) + 1;
        if ((curr[j] ?? 0) > max) max = curr[j] ?? 0;
      } else {
        curr[j] = 0;
      }
    }
    // Swap rows
    for (let j = 0; j <= short.length; j++) {
      prev[j] = curr[j] ?? 0;
      curr[j] = 0;
    }
  }

  return max;
}
