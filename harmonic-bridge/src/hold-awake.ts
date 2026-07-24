// Keeps the host machine visibly active while wake commands run.
//
// On hibernating hosts (Fly Sprites and similar), the platform freezes the
// machine as soon as no connection or interactive session is open — runnable
// processes alone don't count as activity. The daemon acks webhooks
// immediately, so without countermeasures the machine can freeze before the
// spawned wake command opens its first outbound connection, pausing the wake
// indefinitely.
//
// The countermeasure: while at least one wake is running, keep one HTTP
// request open against the daemon's own public URL (the /hold route). The
// connection hairpins through the platform edge, which is what makes the
// activity visible to the idle detector; the route streams heartbeat bytes
// so intermediaries don't reap it as idle. Refcounted so overlapping wakes
// share a single connection.
//
// Establishment races the freeze: the hold needs DNS + TLS through the edge
// (~0.5–1s), and the platform can freeze faster than that once the webhook
// connection closes. `prime()` exists so the server can hold the webhook
// response open until the hold is established — while the inbound request
// is open the machine can't freeze, so acking only after establishment
// removes the race entirely.

export interface HoldAwakeOpts {
  /** URL to hold open — the daemon's own `${public_url}/hold`. */
  readonly url: string;
  /** Delay before re-opening a dropped connection while still held. */
  readonly reconnectDelayMs?: number;
  /**
   * How long a prime()'s acquire lingers after establishment before
   * auto-releasing. Long enough for the dispatched wake's own acquire to
   * take over the refcount.
   */
  readonly primeGraceMs?: number;
  /**
   * Called when a hold attempt fails while still held (never for
   * deliberate release/stop aborts). Receives the consecutive-failure
   * count so callers can rate-limit their logging.
   */
  readonly onError?: (error: unknown, consecutiveFailures: number) => void;
}

export interface HoldAwake {
  acquire(): void;
  release(): void;
  /**
   * Acquire and resolve once the hold connection is established (or after
   * timeoutMs if it can't be). The acquire auto-releases after primeGraceMs;
   * never rejects. Used by the server to delay webhook acks until the
   * machine is provably held.
   */
  prime(timeoutMs: number): Promise<void>;
  /** Abort any open connection and prevent reconnects. Idempotent. */
  stop(): Promise<void>;
}

const DEFAULT_RECONNECT_DELAY_MS = 250;
const DEFAULT_PRIME_GRACE_MS = 10_000;

export function createHoldAwake(opts: HoldAwakeOpts): HoldAwake {
  const reconnectDelayMs = opts.reconnectDelayMs ?? DEFAULT_RECONNECT_DELAY_MS;
  const primeGraceMs = opts.primeGraceMs ?? DEFAULT_PRIME_GRACE_MS;
  let count = 0;
  let stopped = false;
  let controller: AbortController | null = null;
  let loop: Promise<void> | null = null;
  let established = false;
  let consecutiveFailures = 0;
  let establishedWaiters: Array<() => void> = [];

  function flagEstablished(): void {
    established = true;
    consecutiveFailures = 0;
    const waiters = establishedWaiters;
    establishedWaiters = [];
    for (const w of waiters) w();
  }

  async function holdOnce(): Promise<void> {
    controller = new AbortController();
    try {
      const res = await fetch(opts.url, { signal: controller.signal });
      // Headers arriving through the edge means the connection is live.
      flagEstablished();
      if (res.body) {
        const reader = res.body.getReader();
        // Consume heartbeats until the stream ends (server/edge closed it)
        // or release()/stop() aborts the request.
        for (;;) {
          const { done } = await reader.read();
          if (done) break;
        }
      }
    } catch (e) {
      // Deliberate aborts (release/stop) also land here; only report
      // failures that happened while the hold was still wanted.
      if (count > 0 && !stopped) {
        consecutiveFailures += 1;
        opts.onError?.(e, consecutiveFailures);
      }
    } finally {
      established = false;
      controller = null;
    }
  }

  async function runLoop(): Promise<void> {
    while (count > 0 && !stopped) {
      await holdOnce();
      if (count > 0 && !stopped) {
        await new Promise((r) => setTimeout(r, reconnectDelayMs));
      }
    }
    loop = null;
    // An acquire may have landed between the while-check and loop=null;
    // restart so a held count never sits without a connection.
    if (count > 0 && !stopped) loop = runLoop();
  }

  function waitEstablished(timeoutMs: number): Promise<void> {
    if (established || stopped) return Promise.resolve();
    return new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        establishedWaiters = establishedWaiters.filter((w) => w !== waiter);
        resolve();
      }, timeoutMs);
      const waiter = () => {
        clearTimeout(timer);
        resolve();
      };
      establishedWaiters.push(waiter);
    });
  }

  function acquire(): void {
    count += 1;
    if (!stopped && loop === null) loop = runLoop();
  }

  function release(): void {
    if (count === 0) throw new Error("hold-awake: release without matching acquire");
    count -= 1;
    if (count === 0) controller?.abort();
  }

  return {
    acquire,
    release,
    async prime(timeoutMs: number): Promise<void> {
      acquire();
      await waitEstablished(timeoutMs);
      setTimeout(release, primeGraceMs);
    },
    async stop() {
      stopped = true;
      controller?.abort();
      const waiters = establishedWaiters;
      establishedWaiters = [];
      for (const w of waiters) w();
      if (loop) await loop.catch(() => undefined);
    },
  };
}
