import { describe, it, expect } from "vitest";
import { RateLimiter } from "../../src/gateway/RateLimiter.js";

const makeClock = () => {
  let t = 1_000_000;
  return {
    now: () => t,
    advance: (ms: number) => {
      t += ms;
    },
  };
};

describe("RateLimiter", () => {
  it("allows requests under the per-minute limit", () => {
    const clock = makeClock();
    const limiter = new RateLimiter({ perMinute: 3, perDay: 100, now: clock.now });

    for (let i = 0; i < 3; i++) {
      expect(limiter.check("key-a").allowed).toBe(true);
    }
  });

  it("blocks over the per-minute limit and reports when to retry", () => {
    const clock = makeClock();
    const limiter = new RateLimiter({ perMinute: 2, perDay: 100, now: clock.now });

    limiter.check("key-a");
    clock.advance(10_000);
    limiter.check("key-a");

    const decision = limiter.check("key-a");
    expect(decision.allowed).toBe(false);
    // The oldest request exits the 60s window 50s from now.
    expect(decision.retryAfterSeconds).toBe(50);
  });

  it("allows again after the minute window slides past", () => {
    const clock = makeClock();
    const limiter = new RateLimiter({ perMinute: 1, perDay: 100, now: clock.now });

    expect(limiter.check("key-a").allowed).toBe(true);
    expect(limiter.check("key-a").allowed).toBe(false);

    clock.advance(61_000);
    expect(limiter.check("key-a").allowed).toBe(true);
  });

  it("enforces the per-day limit even when the per-minute rate is fine", () => {
    const clock = makeClock();
    const limiter = new RateLimiter({ perMinute: 10, perDay: 3, now: clock.now });

    for (let i = 0; i < 3; i++) {
      expect(limiter.check("key-a").allowed).toBe(true);
      clock.advance(120_000);
    }

    const decision = limiter.check("key-a");
    expect(decision.allowed).toBe(false);
    expect(decision.retryAfterSeconds).toBeGreaterThan(0);

    clock.advance(24 * 60 * 60 * 1000);
    expect(limiter.check("key-a").allowed).toBe(true);
  });

  it("blocked requests do not consume quota", () => {
    const clock = makeClock();
    const limiter = new RateLimiter({ perMinute: 1, perDay: 100, now: clock.now });

    limiter.check("key-a");
    limiter.check("key-a");
    limiter.check("key-a");

    clock.advance(61_000);
    expect(limiter.check("key-a").allowed).toBe(true);
  });

  it("tracks keys independently", () => {
    const clock = makeClock();
    const limiter = new RateLimiter({ perMinute: 1, perDay: 100, now: clock.now });

    expect(limiter.check("key-a").allowed).toBe(true);
    expect(limiter.check("key-a").allowed).toBe(false);
    expect(limiter.check("key-b").allowed).toBe(true);
  });
});
