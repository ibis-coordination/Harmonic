/**
 * Per-key sliding-window rate limiter for the gateway's external ingress.
 *
 * A leaked llm_gateway key spends other people's money until the pool is dry;
 * Stripe's 402 bounds the total but not the burn rate. This bounds requests
 * per minute and per day per key until real dollar spend ceilings exist
 * (which need per-call usage persistence).
 *
 * In-memory on purpose: the gateway runs as a single container, so there is
 * no shared state to coordinate. If the gateway is ever scaled out, the
 * limits become per-instance and this needs a shared store.
 */

export interface RateLimiterOptions {
  readonly perMinute: number;
  readonly perDay: number;
  /** Injectable clock (ms since epoch) for tests. */
  readonly now?: () => number;
}

export interface RateLimitDecision {
  readonly allowed: boolean;
  /** Seconds until the next request could be allowed; 0 when allowed. */
  readonly retryAfterSeconds: number;
}

const MINUTE_MS = 60_000;
const DAY_MS = 24 * 60 * 60 * 1000;

export class RateLimiter {
  private readonly perMinute: number;
  private readonly perDay: number;
  private readonly now: () => number;
  /** Per key: request timestamps within the last day, oldest first. */
  private readonly requests = new Map<string, number[]>();

  constructor(options: RateLimiterOptions) {
    this.perMinute = options.perMinute;
    this.perDay = options.perDay;
    this.now = options.now ?? Date.now;
  }

  /** Record the request if allowed; blocked requests consume no quota. */
  check(key: string): RateLimitDecision {
    const now = this.now();
    const dayCutoff = now - DAY_MS;

    const kept = (this.requests.get(key) ?? []).filter((t) => t > dayCutoff);
    if (kept.length === 0) {
      this.requests.delete(key);
    }

    if (kept.length >= this.perDay) {
      // kept[0] is the oldest in-window request; quota frees when it ages out.
      return this.blocked(kept[0]! + DAY_MS - now);
    }

    const minuteCutoff = now - MINUTE_MS;
    const inLastMinute = kept.filter((t) => t > minuteCutoff);
    if (inLastMinute.length >= this.perMinute) {
      return this.blocked(inLastMinute[0]! + MINUTE_MS - now);
    }

    kept.push(now);
    this.requests.set(key, kept);
    return { allowed: true, retryAfterSeconds: 0 };
  }

  private blocked(retryAfterMs: number): RateLimitDecision {
    return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil(retryAfterMs / 1000)) };
  }
}
