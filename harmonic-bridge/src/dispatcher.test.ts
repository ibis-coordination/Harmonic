import { test } from "node:test";
import assert from "node:assert/strict";
import { createDispatcher } from "./dispatcher.js";

function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

test("dispatch: serializes events for the same agent in arrival order", async () => {
  const order: string[] = [];
  const dispatcher = createDispatcher<string>(async (handle, payload) => {
    order.push(`${handle}:${payload}:start`);
    await new Promise((r) => setTimeout(r, 10));
    order.push(`${handle}:${payload}:end`);
  });

  dispatcher.dispatch("alice", "1");
  dispatcher.dispatch("alice", "2");
  dispatcher.dispatch("alice", "3");

  await dispatcher.drain();

  assert.deepEqual(order, [
    "alice:1:start", "alice:1:end",
    "alice:2:start", "alice:2:end",
    "alice:3:start", "alice:3:end",
  ]);
});

test("dispatch: different agents run in parallel", async () => {
  const aliceGate = deferred();
  const bobStarted = deferred();

  const dispatcher = createDispatcher<string>(async (handle, _payload) => {
    if (handle === "alice") {
      await aliceGate.promise;
    } else if (handle === "bob") {
      bobStarted.resolve();
    }
  });

  dispatcher.dispatch("alice", "1");
  dispatcher.dispatch("bob", "1");

  // Bob should start without waiting for Alice — if the dispatcher
  // serialized across agents, this would hang.
  await bobStarted.promise;
  aliceGate.resolve();
  await dispatcher.drain();
});

test("dispatch: runner error doesn't break the agent's queue", async () => {
  const ran: string[] = [];
  const dispatcher = createDispatcher<string>(async (_handle, payload) => {
    ran.push(payload);
    if (payload === "boom") throw new Error("simulated failure");
  });

  dispatcher.dispatch("alice", "1");
  dispatcher.dispatch("alice", "boom");
  dispatcher.dispatch("alice", "3");

  await dispatcher.drain();

  assert.deepEqual(ran, ["1", "boom", "3"]);
});

test("dispatch: drainAgent waits only for that agent's queue", async () => {
  const aliceGate = deferred();
  const bobGate = deferred();

  const dispatcher = createDispatcher<string>(async (handle, _payload) => {
    if (handle === "alice") await aliceGate.promise;
    if (handle === "bob") await bobGate.promise;
  });

  dispatcher.dispatch("alice", "1");
  dispatcher.dispatch("bob", "1");

  // Release alice, await drainAgent("alice"); bob is still blocked.
  aliceGate.resolve();
  await dispatcher.drainAgent("alice");

  // Now release bob; final drain should complete.
  bobGate.resolve();
  await dispatcher.drain();
});

test("dispatch: drain on empty dispatcher resolves immediately", async () => {
  const dispatcher = createDispatcher<string>(async () => undefined);
  await dispatcher.drain();
  await dispatcher.drainAgent("never-dispatched");
});

test("dispatch: many events on one agent stay strictly serialized", async () => {
  let active = 0;
  let maxActive = 0;
  const dispatcher = createDispatcher<number>(async (_handle, _payload) => {
    active++;
    maxActive = Math.max(maxActive, active);
    await new Promise((r) => setTimeout(r, 1));
    active--;
  });

  for (let i = 0; i < 20; i++) dispatcher.dispatch("alice", i);

  await dispatcher.drain();
  assert.equal(maxActive, 1, `expected strict serialization, saw ${maxActive} concurrent`);
});
