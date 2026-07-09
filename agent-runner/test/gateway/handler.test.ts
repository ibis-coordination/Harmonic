import { describe, it, expect, afterEach } from "vitest";
import { createServer, type Server } from "node:http";
import { createHandler, type RelayRunner } from "../../src/gateway/handler.js";
import type { GatewayRelayRequest } from "../../src/gateway/Relay.js";

let running: Server | undefined;

afterEach(async () => {
  if (running) {
    await new Promise<void>((resolve) => running!.close(() => resolve()));
    running = undefined;
  }
});

const start = (runRelay: RelayRunner): Promise<string> =>
  new Promise((resolve) => {
    const handler = createHandler(runRelay);
    running = createServer((req, res) => void handler(req, res));
    running.listen(0, () => {
      const addr = running!.address();
      const port = typeof addr === "object" && addr !== null ? addr.port : 0;
      resolve(`http://127.0.0.1:${port}`);
    });
  });

const okRelay: RelayRunner = async () => ({ status: 200, body: JSON.stringify({ ok: true }) });

describe("gateway handler", () => {
  it("serves health without invoking the relay", async () => {
    let called = false;
    const url = await start(async (r) => {
      called = true;
      return okRelay(r);
    });

    const res = await fetch(`${url}/health`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "ok" });
    expect(called).toBe(false);
  });

  it("passes routing headers and body through to the relay and returns its result", async () => {
    let captured: GatewayRelayRequest | undefined;
    const url = await start(async (r) => {
      captured = r;
      return { status: 200, body: JSON.stringify({ echoed: true }) };
    });

    const res = await fetch(`${url}/chat/completions`, {
      method: "POST",
      headers: {
        "X-Harmonic-Task-Run-Id": "task-run-9",
        "X-Harmonic-Subdomain": "acme",
        "X-Harmonic-Model": "anthropic/claude-sonnet-4.6",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ messages: [] }),
    });

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ echoed: true });
    expect(captured).toEqual({
      taskRunId: "task-run-9",
      subdomain: "acme",
      model: "anthropic/claude-sonnet-4.6",
      body: JSON.stringify({ messages: [] }),
    });
  });

  it("rejects a POST missing routing headers without invoking the relay", async () => {
    let called = false;
    const url = await start(async (r) => {
      called = true;
      return okRelay(r);
    });

    const res = await fetch(`${url}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });

    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "missing_routing_headers" });
    expect(called).toBe(false);
  });

  it("returns 405 for a non-POST, non-health request", async () => {
    const url = await start(okRelay);
    const res = await fetch(`${url}/chat/completions`, { method: "GET" });
    expect(res.status).toBe(405);
  });

  it("maps a relay exception to 502", async () => {
    const url = await start(async () => {
      throw new Error("boom");
    });

    const res = await fetch(`${url}/chat/completions`, {
      method: "POST",
      headers: {
        "X-Harmonic-Task-Run-Id": "task-run-9",
        "X-Harmonic-Subdomain": "acme",
      },
      body: "{}",
    });

    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "gateway_error" });
  });
});
