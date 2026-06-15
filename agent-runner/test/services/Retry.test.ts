import { describe, it, expect } from "vitest";
import { withRetryAfter, createRetryBudget, type RetryBudget } from "../../src/services/Retry.js";

interface FakeResponse {
  statusCode: number;
  headers: Record<string, string | string[] | undefined>;
  bodyDrained: boolean;
  text: () => Promise<string>;
}

function makeResponse(statusCode: number, headers: Record<string, string> = {}): FakeResponse {
  const resp: FakeResponse = {
    statusCode,
    headers,
    bodyDrained: false,
    text: async () => {
      resp.bodyDrained = true;
      return "";
    },
  };
  return resp;
}

function spy(): { calls: number; sleeps: number[]; sleep: (ms: number) => Promise<void> } {
  const sleeps: number[] = [];
  return {
    calls: 0,
    sleeps,
    sleep: async (ms: number) => {
      sleeps.push(ms);
    },
  };
}

describe("withRetryAfter", () => {
  it("passes a non-429 response through unchanged without sleeping", async () => {
    const budget: RetryBudget = createRetryBudget();
    const startBudget = budget.remainingMs;
    const s = spy();
    let calls = 0;
    const result = await withRetryAfter(budget, async () => {
      calls += 1;
      return makeResponse(200);
    }, s.sleep);

    expect(result.statusCode).toBe(200);
    expect(calls).toBe(1);
    expect(s.sleeps).toEqual([]);
    expect(budget.remainingMs).toBe(startBudget);
  });

  it("retries once on 429 with Retry-After, returns the retry result on success", async () => {
    const budget: RetryBudget = createRetryBudget(60_000);
    const s = spy();
    const responses = [makeResponse(429, { "retry-after": "2" }), makeResponse(200)];
    let i = 0;
    const result = await withRetryAfter(budget, async () => {
      return responses[i++]!;
    }, s.sleep);

    expect(result.statusCode).toBe(200);
    expect(i).toBe(2);
    expect(s.sleeps).toEqual([2000]);
    expect(budget.remainingMs).toBe(60_000 - 2000);
    expect(responses[0]!.bodyDrained).toBe(true);
  });

  it("returns the second 429 if the retry also 429s (caller surfaces to LLM)", async () => {
    const budget: RetryBudget = createRetryBudget(60_000);
    const s = spy();
    const responses = [
      makeResponse(429, { "retry-after": "1" }),
      makeResponse(429, { "retry-after": "1" }),
    ];
    let i = 0;
    const result = await withRetryAfter(budget, async () => {
      return responses[i++]!;
    }, s.sleep);

    expect(result.statusCode).toBe(429);
    expect(i).toBe(2);
    expect(s.sleeps).toEqual([1000]);
  });

  it("returns 429 immediately if Retry-After exceeds remaining budget (no sleep, no retry)", async () => {
    const budget: RetryBudget = { remainingMs: 500 }; // 0.5s remaining
    const s = spy();
    let calls = 0;
    const result = await withRetryAfter(budget, async () => {
      calls += 1;
      return makeResponse(429, { "retry-after": "10" }); // wants 10s
    }, s.sleep);

    expect(result.statusCode).toBe(429);
    expect(calls).toBe(1);
    expect(s.sleeps).toEqual([]);
    expect(budget.remainingMs).toBe(500);
  });

  it("treats missing Retry-After as no-retry (returns the 429)", async () => {
    const budget: RetryBudget = createRetryBudget();
    const s = spy();
    let calls = 0;
    const result = await withRetryAfter(budget, async () => {
      calls += 1;
      return makeResponse(429); // no Retry-After header
    }, s.sleep);

    expect(result.statusCode).toBe(429);
    expect(calls).toBe(1);
    expect(s.sleeps).toEqual([]);
  });

  it("treats malformed Retry-After as no-retry", async () => {
    const budget: RetryBudget = createRetryBudget();
    const s = spy();
    let calls = 0;
    const result = await withRetryAfter(budget, async () => {
      calls += 1;
      return makeResponse(429, { "retry-after": "not-a-number" });
    }, s.sleep);

    expect(result.statusCode).toBe(429);
    expect(calls).toBe(1);
    expect(s.sleeps).toEqual([]);
  });

  it("budget depletes across multiple retried calls within a task", async () => {
    const budget: RetryBudget = createRetryBudget(5_000); // 5s
    const s = spy();

    // First call: 429+1s → success after 1s sleep. Budget: 5s → 4s.
    let i = 0;
    const r1 = await withRetryAfter(budget, async () => {
      const resp = [makeResponse(429, { "retry-after": "1" }), makeResponse(200)][i++]!;
      return resp;
    }, s.sleep);
    expect(r1.statusCode).toBe(200);
    expect(budget.remainingMs).toBe(4_000);

    // Second call: 429+3s → success after 3s sleep. Budget: 4s → 1s.
    let j = 0;
    const r2 = await withRetryAfter(budget, async () => {
      const resp = [makeResponse(429, { "retry-after": "3" }), makeResponse(200)][j++]!;
      return resp;
    }, s.sleep);
    expect(r2.statusCode).toBe(200);
    expect(budget.remainingMs).toBe(1_000);

    // Third call: 429+2s requested but only 1s left → return 429 immediately.
    let k = 0;
    const r3 = await withRetryAfter(budget, async () => {
      k += 1;
      return makeResponse(429, { "retry-after": "2" });
    }, s.sleep);
    expect(r3.statusCode).toBe(429);
    expect(k).toBe(1);
    expect(budget.remainingMs).toBe(1_000);

    expect(s.sleeps).toEqual([1_000, 3_000]);
  });
});
