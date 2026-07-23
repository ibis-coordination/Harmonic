import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createServer as createHttpServer, type Server, type ServerResponse } from "node:http";
import { createHoldAwake, type HoldAwake } from "./hold-awake.js";

const HOST = "127.0.0.1";

function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

// Stand-in for the platform edge + daemon /hold route: accepts connections,
// holds them open (streaming a heartbeat so proxies don't reap them), and
// records opens/closes.
interface StubEdge {
  url: string;
  opens: number;
  closes: number;
  onOpen: () => void;
  onClose: () => void;
  /** Destroy all live connections server-side (simulates edge reaping). */
  reapAll(): void;
  close(): Promise<void>;
}

async function startStubEdge(): Promise<StubEdge> {
  const live = new Set<ServerResponse>();
  const stub: { current: StubEdge | null } = { current: null };
  const server: Server = createHttpServer((req, res) => {
    stub.current!.opens += 1;
    stub.current!.onOpen();
    live.add(res);
    res.writeHead(200, { "Content-Type": "text/plain" });
    const beat = setInterval(() => res.write("h\n"), 10);
    res.on("close", () => {
      clearInterval(beat);
      live.delete(res);
      stub.current!.closes += 1;
      stub.current!.onClose();
    });
  });
  await new Promise<void>((resolve) => server.listen(0, HOST, resolve));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  stub.current = {
    url: `http://${HOST}:${port}/hold`,
    opens: 0,
    closes: 0,
    onOpen: () => undefined,
    onClose: () => undefined,
    reapAll: () => {
      for (const res of live) res.destroy();
    },
    close: () =>
      new Promise<void>((resolve) => {
        for (const res of live) res.destroy();
        server.close(() => resolve());
      }),
  };
  return stub.current;
}

const cleanups: Array<() => Promise<void>> = [];
after(async () => {
  for (const fn of cleanups) await fn();
});

function track(edge: StubEdge, hold: HoldAwake): void {
  cleanups.push(async () => {
    await hold.stop();
    await edge.close();
  });
}

async function eventually(check: () => boolean, label: string, timeoutMs = 2000): Promise<void> {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > timeoutMs) assert.fail(`timed out waiting for: ${label}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

test("hold-awake: acquire opens a held connection; release closes it", async () => {
  const edge = await startStubEdge();
  const hold = createHoldAwake({ url: edge.url });
  track(edge, hold);

  const opened = deferred();
  edge.onOpen = opened.resolve;

  hold.acquire();
  await opened.promise;
  assert.equal(edge.opens, 1);
  assert.equal(edge.closes, 0);

  const closed = deferred();
  edge.onClose = closed.resolve;
  hold.release();
  await closed.promise;
  assert.equal(edge.closes, 1);
});

test("hold-awake: overlapping acquires share one connection; last release closes", async () => {
  const edge = await startStubEdge();
  const hold = createHoldAwake({ url: edge.url });
  track(edge, hold);

  const opened = deferred();
  edge.onOpen = opened.resolve;

  hold.acquire();
  hold.acquire();
  await opened.promise;
  // Give a beat for any (incorrect) second connection to show up.
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(edge.opens, 1);

  hold.release();
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(edge.closes, 0, "connection must stay open while one acquire remains");

  const closed = deferred();
  edge.onClose = closed.resolve;
  hold.release();
  await closed.promise;
  assert.equal(edge.closes, 1);
});

test("hold-awake: reconnects if the connection drops while held", async () => {
  const edge = await startStubEdge();
  const hold = createHoldAwake({ url: edge.url, reconnectDelayMs: 10 });
  track(edge, hold);

  const opened = deferred();
  edge.onOpen = opened.resolve;
  hold.acquire();
  await opened.promise;

  edge.reapAll();
  await eventually(() => edge.opens >= 2, "reconnect after server-side reap");

  hold.release();
});

test("hold-awake: stop closes the connection and prevents reconnects", async () => {
  const edge = await startStubEdge();
  const hold = createHoldAwake({ url: edge.url, reconnectDelayMs: 10 });
  track(edge, hold);

  const opened = deferred();
  edge.onOpen = opened.resolve;
  hold.acquire();
  await opened.promise;

  await hold.stop();
  const opensAtStop = edge.opens;
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(edge.opens, opensAtStop, "no reconnect after stop");
  assert.equal(edge.closes, edge.opens, "all connections closed after stop");
});

test("hold-awake: prime resolves once the connection is established", async () => {
  const edge = await startStubEdge();
  const hold = createHoldAwake({ url: edge.url, primeGraceMs: 100 });
  track(edge, hold);

  await hold.prime(2000);
  assert.equal(edge.opens, 1, "prime must have opened the connection before resolving");

  // After the grace period the prime's acquire is auto-released.
  await eventually(() => edge.closes === 1, "prime auto-release after grace");
});

test("hold-awake: prime keeps the hold if a real acquire lands within the grace period", async () => {
  const edge = await startStubEdge();
  const hold = createHoldAwake({ url: edge.url, primeGraceMs: 50 });
  track(edge, hold);

  await hold.prime(2000);
  hold.acquire();
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(edge.closes, 0, "connection must survive the prime grace expiry while acquired");

  hold.release();
  await eventually(() => edge.closes === 1, "close after final release");
});

test("hold-awake: prime resolves after its timeout when the hold URL is unreachable", async () => {
  // Point at a port that nothing listens on — establishment can never happen.
  const hold = createHoldAwake({ url: `http://${HOST}:1/hold`, reconnectDelayMs: 10, primeGraceMs: 50 });
  cleanups.push(() => hold.stop());

  const start = Date.now();
  await hold.prime(100);
  const elapsed = Date.now() - start;
  assert.ok(elapsed >= 90, `prime should wait for its timeout (waited ${elapsed}ms)`);
  assert.ok(elapsed < 1500, `prime must not hang far past its timeout (waited ${elapsed}ms)`);
});

test("hold-awake: release below zero throws", async () => {
  const edge = await startStubEdge();
  const hold = createHoldAwake({ url: edge.url });
  track(edge, hold);

  assert.throws(() => hold.release(), /release without matching acquire/);
});
