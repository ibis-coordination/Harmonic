/**
 * Per-agent concurrency control — Effect service.
 * Ensures only one task runs per agent at a time using an in-memory Set.
 */

import { Context, Effect, Layer } from "effect";

export interface AgentLockService {
  readonly tryAcquire: (agentId: string) => Effect.Effect<boolean>;
  readonly release: (agentId: string) => Effect.Effect<void>;
}

export class AgentLock extends Context.Tag("AgentLock")<AgentLock, AgentLockService>() {}

export const AgentLockLive = Layer.sync(AgentLock, () => {
  const activeAgents = new Set<string>();

  return {
    tryAcquire: (agentId: string) =>
      Effect.sync(() => {
        if (activeAgents.has(agentId)) {
          return false;
        }
        activeAgents.add(agentId);
        return true;
      }),

    release: (agentId: string) =>
      Effect.sync(() => {
        activeAgents.delete(agentId);
      }),
  };
});
