import { describe, it, expect } from "vitest";
import { Effect } from "effect";
import { AgentLock, AgentLockLive } from "../../src/services/AgentLock.js";

const runWithLock = <A>(effect: Effect.Effect<A, never, AgentLock>) =>
  Effect.runSync(Effect.provide(effect, AgentLockLive));

describe("AgentLock", () => {
  it("acquires lock for new agent", () => {
    const result = runWithLock(
      Effect.gen(function* () {
        const lock = yield* AgentLock;
        const acquired = yield* lock.tryAcquire("agent-1");
        yield* lock.release("agent-1");
        return acquired;
      }),
    );
    expect(result).toBe(true);
  });

  it("blocks concurrent lock for same agent", () => {
    const result = runWithLock(
      Effect.gen(function* () {
        const lock = yield* AgentLock;
        yield* lock.tryAcquire("agent-1");
        const second = yield* lock.tryAcquire("agent-1");
        yield* lock.release("agent-1");
        return second;
      }),
    );
    expect(result).toBe(false);
  });

  it("allows lock for different agents", () => {
    const result = runWithLock(
      Effect.gen(function* () {
        const lock = yield* AgentLock;
        const first = yield* lock.tryAcquire("agent-1");
        const second = yield* lock.tryAcquire("agent-2");
        yield* lock.release("agent-1");
        yield* lock.release("agent-2");
        return { first, second };
      }),
    );
    expect(result.first).toBe(true);
    expect(result.second).toBe(true);
  });

  it("releases lock allowing re-acquisition", () => {
    const result = runWithLock(
      Effect.gen(function* () {
        const lock = yield* AgentLock;
        yield* lock.tryAcquire("agent-1");
        yield* lock.release("agent-1");
        const reacquired = yield* lock.tryAcquire("agent-1");
        yield* lock.release("agent-1");
        return reacquired;
      }),
    );
    expect(result).toBe(true);
  });
});
