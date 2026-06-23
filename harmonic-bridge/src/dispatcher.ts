// Per-agent FIFO queue. Each agent gets its own promise chain so concurrent
// webhooks for the same agent serialize (one wake at a time, in arrival
// order), while different agents run in parallel.
//
// The actual work — spawning the wake command, resolving secrets, streaming
// logs — lives in the runner the caller passes in. This module is just the
// serialization primitive.

export interface Dispatcher<P> {
  /** Queue an event for the named agent. Returns immediately. */
  dispatch(agentHandle: string, payload: P): void;
  /** Wait for all queued events across all agents to finish. */
  drain(): Promise<void>;
  /** Wait for one agent's queue to finish (useful for shutdown). */
  drainAgent(agentHandle: string): Promise<void>;
}

export function createDispatcher<P>(
  runner: (agentHandle: string, payload: P) => Promise<void>,
): Dispatcher<P> {
  const queues = new Map<string, Promise<void>>();

  function dispatch(agentHandle: string, payload: P): void {
    const previous = queues.get(agentHandle) ?? Promise.resolve();
    // Swallow runner errors so one failure doesn't poison the queue —
    // each event runs on a clean slate. The runner is expected to log /
    // surface its own failures; the dispatcher only owns ordering.
    const next = previous.then(() => runner(agentHandle, payload).catch(() => undefined));
    queues.set(agentHandle, next);
  }

  async function drainAgent(agentHandle: string): Promise<void> {
    const p = queues.get(agentHandle);
    if (p) await p;
  }

  async function drain(): Promise<void> {
    await Promise.all([...queues.values()]);
  }

  return { dispatch, drain, drainAgent };
}
