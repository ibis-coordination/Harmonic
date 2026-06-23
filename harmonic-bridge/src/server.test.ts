import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { type AgentResolution, type RunningServer, startServer } from "./server.js";

const HOST = "127.0.0.1";
const TS = 1735200000;

function sign(body: string, ts: number, secret: string): string {
  const hex = createHmac("sha256", secret).update(`${ts}.${body}`).digest("hex");
  return `sha256=${hex}`;
}

interface Capture {
  handle: string;
  eventType: string;
  payload: string;
}

interface Harness {
  server: RunningServer;
  baseUrl: string;
  captured: Capture[];
  agents: Map<string, AgentResolution>;
}

async function start(opts?: { agents?: Map<string, AgentResolution> }): Promise<Harness> {
  const agents = opts?.agents ?? new Map<string, AgentResolution>();
  const captured: Capture[] = [];
  const server = await startServer({
    listen: { host: HOST, port: 0 },
    resolveAgent: async (handle) => agents.get(handle) ?? null,
    onEvent: (handle, eventType, payload) => {
      captured.push({ handle, eventType, payload });
    },
    now: () => TS,
  });
  return { server, baseUrl: `http://${HOST}:${server.port}`, captured, agents };
}

const harnesses: Harness[] = [];

async function startTracked(opts?: { agents?: Map<string, AgentResolution> }): Promise<Harness> {
  const h = await start(opts);
  harnesses.push(h);
  return h;
}

after(async () => {
  await Promise.all(harnesses.map((h) => h.server.close()));
});

test("server: valid signed request returns 204 and emits the event", async () => {
  const agents = new Map<string, AgentResolution>([["melody", { webhookSecret: "s3cret" }]]);
  const h = await startTracked({ agents });
  const body = '{"event":"notifications.delivered","data":1}';
  const res = await fetch(`${h.baseUrl}/webhook/melody`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, "s3cret"),
      "X-Harmonic-Timestamp": String(TS),
      "X-Harmonic-Event": "notifications.delivered",
      "Content-Type": "application/json",
    },
    body,
  });
  assert.equal(res.status, 204);
  // Give the post-ack handler a tick to record the event.
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(h.captured.length, 1);
  assert.deepEqual(h.captured[0], { handle: "melody", eventType: "notifications.delivered", payload: body });
});

test("server: bad signature returns 401 and doesn't emit", async () => {
  const agents = new Map<string, AgentResolution>([["melody", { webhookSecret: "s3cret" }]]);
  const h = await startTracked({ agents });
  const body = "{}";
  const res = await fetch(`${h.baseUrl}/webhook/melody`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": "sha256=" + "0".repeat(64),
      "X-Harmonic-Timestamp": String(TS),
    },
    body,
  });
  assert.equal(res.status, 401);
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(h.captured.length, 0);
});

test("server: missing signature header returns 401", async () => {
  const agents = new Map<string, AgentResolution>([["melody", { webhookSecret: "s3cret" }]]);
  const h = await startTracked({ agents });
  const res = await fetch(`${h.baseUrl}/webhook/melody`, {
    method: "POST",
    headers: { "X-Harmonic-Timestamp": String(TS) },
    body: "{}",
  });
  assert.equal(res.status, 401);
});

test("server: unknown agent returns 404", async () => {
  const h = await startTracked();
  const res = await fetch(`${h.baseUrl}/webhook/missing`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign("{}", TS, "x"),
      "X-Harmonic-Timestamp": String(TS),
    },
    body: "{}",
  });
  assert.equal(res.status, 404);
});

test("server: non-POST returns 405", async () => {
  const agents = new Map<string, AgentResolution>([["melody", { webhookSecret: "s3cret" }]]);
  const h = await startTracked({ agents });
  const res = await fetch(`${h.baseUrl}/webhook/melody`);
  assert.equal(res.status, 405);
});

test("server: wrong path returns 404", async () => {
  const h = await startTracked();
  const res = await fetch(`${h.baseUrl}/not/a/webhook`, { method: "POST", body: "{}" });
  assert.equal(res.status, 404);
});

test("server: oversize body returns 413", async () => {
  const agents = new Map<string, AgentResolution>([["melody", { webhookSecret: "s3cret" }]]);
  const h = await startTracked({ agents });
  const huge = "x".repeat(2000);
  const customServer = await startServer({
    listen: { host: HOST, port: 0 },
    resolveAgent: async (handle) => agents.get(handle) ?? null,
    onEvent: () => undefined,
    now: () => TS,
    maxBodyBytes: 1000,
  });
  harnesses.push({
    server: customServer,
    baseUrl: `http://${HOST}:${customServer.port}`,
    captured: [],
    agents,
  });
  const res = await fetch(`http://${HOST}:${customServer.port}/webhook/melody`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(huge, TS, "s3cret"),
      "X-Harmonic-Timestamp": String(TS),
    },
    body: huge,
  });
  assert.equal(res.status, 413);
});

test("server: handle with hyphen routes correctly", async () => {
  const agents = new Map<string, AgentResolution>([["harmonic-dev", { webhookSecret: "s3cret" }]]);
  const h = await startTracked({ agents });
  const body = "{}";
  const res = await fetch(`${h.baseUrl}/webhook/harmonic-dev`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, "s3cret"),
      "X-Harmonic-Timestamp": String(TS),
    },
    body,
  });
  assert.equal(res.status, 204);
});
