/**
 * Retry-After backoff for Harmonic API requests.
 *
 * The hosted MCP endpoint (and other rate-limited Harmonic endpoints) return
 * HTTP 429 with a `Retry-After` header (integer seconds) when one of the
 * four layered rate-limit scopes (per-token burst/sustained, per-principal,
 * per-tenant aggregate) is breached. A well-behaved client respects the
 * Retry-After delay rather than expecting elevated limits.
 *
 * Policy
 * ------
 * - On 429 with a positive integer Retry-After: sleep for that duration,
 *   retry the same request ONCE. If the retry also 429s, surface that
 *   response to the caller (which forwards it to the LLM as a tool error).
 * - Per-task backoff budget caps cumulative sleep time. If the requested
 *   Retry-After exceeds the remaining budget, don't sleep — return the 429
 *   immediately. Prevents a sustained-throttle scenario from blowing past
 *   the task's wall-clock budget.
 * - Non-429 responses pass through unchanged.
 * - Missing / malformed Retry-After is treated as "don't retry" (no sleep,
 *   return the 429). Conservative: better to surface than to guess a delay.
 *
 * Defaults
 * --------
 * Per-task budget defaults to 60 seconds. This is a coarse first cut —
 * tune by observing real 429+backoff events logged by the runner.
 */

const DEFAULT_BUDGET_MS = 60_000;

export interface RetryBudget {
  remainingMs: number;
}

export function createRetryBudget(totalMs: number = DEFAULT_BUDGET_MS): RetryBudget {
  return { remainingMs: totalMs };
}

interface RetryableResponse {
  readonly statusCode: number;
  readonly headers: Record<string, string | string[] | undefined>;
  readonly text: () => Promise<string>;
}

/**
 * Wrap a request-producing thunk with Retry-After 429 handling.
 *
 * The `drainBody` callback is invoked on a 429 BEFORE retrying so the
 * underlying socket can be released. Required because undici streams the
 * body and an unread response holds the socket open.
 */
export async function withRetryAfter<T extends RetryableResponse>(
  budget: RetryBudget,
  request: () => Promise<T>,
  sleep: (ms: number) => Promise<void> = defaultSleep,
): Promise<T> {
  const first = await request();
  if (first.statusCode !== 429) return first;

  const retryAfterSec = parseRetryAfterSeconds(first.headers["retry-after"]);
  if (retryAfterSec === null) return first;

  const sleepMs = retryAfterSec * 1000;
  if (sleepMs > budget.remainingMs) return first;

  // Drain the body of the rejected response so undici can free the socket
  // before the retry request opens a new one.
  try {
    await first.text();
  } catch {
    // Body already consumed or transport-level error — proceed regardless.
  }

  budget.remainingMs -= sleepMs;
  await sleep(sleepMs);
  return await request();
}

function parseRetryAfterSeconds(header: string | string[] | undefined): number | null {
  if (typeof header !== "string") return null;
  const n = parseInt(header, 10);
  if (!Number.isFinite(n) || n < 0) return null;
  return n;
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
