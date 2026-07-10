import { describe, it, expect, afterEach } from "vitest";
import { createServer, type Server } from "node:http";
import { createHandler, type RelayRunner, type ExternalRelayRunner, type GatewayHandlerDeps } from "../../src/gateway/handler.js";
import type { GatewayRelayRequest } from "../../src/gateway/Relay.js";
import type { ExternalRelayRequest } from "../../src/gateway/ExternalRelay.js";
import { RateLimiter } from "../../src/gateway/RateLimiter.js";

let running: Server | undefined;

afterEach(async () => {
  if (running) {
    await new Promise<void>((resolve) => running!.close(() => resolve()));
    running = undefined;
  }
});

const okRelay: RelayRunner = async () => ({ status: 200, body: JSON.stringify({ ok: true }) });
const okExternalRelay: ExternalRelayRunner = async () => ({
  status: 200,
  contentType: "application/json",
  body: JSON.stringify({ ok: true }),
});

const start = (deps: Partial<GatewayHandlerDeps>): Promise<string> =>
  new Promise((resolve) => {
    const handler = createHandler({
      runRelay: okRelay,
      runExternalRelay: okExternalRelay,
      rateLimiter: new RateLimiter({ perMinute: 1000, perDay: 10000 }),
      maxBodyBytes: 1024 * 1024,
      ...deps,
    });
    running = createServer((req, res) => void handler(req, res));
    running.listen(0, () => {
      const addr = running!.address();
      const port = typeof addr === "object" && addr !== null ? addr.port : 0;
      resolve(`http://127.0.0.1:${port}`);
    });
  });

describe("gateway handler", () => {
  it("serves health without invoking the relay", async () => {
    let called = false;
    const url = await start({
      runRelay: async (r) => {
        called = true;
        return okRelay(r);
      },
    });

    const res = await fetch(`${url}/health`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "ok" });
    expect(called).toBe(false);
  });

  it("passes routing headers and body through to the relay and returns its result", async () => {
    let captured: GatewayRelayRequest | undefined;
    const url = await start({
      runRelay: async (r) => {
        captured = r;
        return { status: 200, body: JSON.stringify({ echoed: true }) };
      },
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
    const url = await start({
      runRelay: async (r) => {
        called = true;
        return okRelay(r);
      },
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
    const url = await start({});
    const res = await fetch(`${url}/chat/completions`, { method: "GET" });
    expect(res.status).toBe(405);
  });

  it("maps a relay exception to 502", async () => {
    const url = await start({
      runRelay: async () => {
        throw new Error("boom");
      },
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

  describe("external ingress (/v1/chat/completions)", () => {
    it("routes to the external relay with the bearer token and body", async () => {
      let captured: ExternalRelayRequest | undefined;
      const url = await start({
        runExternalRelay: async (r) => {
          captured = r;
          return { status: 200, contentType: "application/json", body: JSON.stringify({ id: "cmpl-1" }) };
        },
      });

      const res = await fetch(`${url}/v1/chat/completions`, {
        method: "POST",
        headers: { "Authorization": "Bearer hg_key_123", "Content-Type": "application/json" },
        body: JSON.stringify({ model: "default", messages: [] }),
      });

      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toBe("application/json");
      expect(await res.json()).toEqual({ id: "cmpl-1" });
      expect(captured).toEqual({
        bearerToken: "hg_key_123",
        body: JSON.stringify({ model: "default", messages: [] }),
      });
    });

    it("streams a ReadableStream result to the client", async () => {
      const url = await start({
        runExternalRelay: async () => ({
          status: 200,
          contentType: "text/event-stream",
          body: new Response("data: one\n\ndata: two\n\n").body!,
        }),
      });

      const res = await fetch(`${url}/v1/chat/completions`, {
        method: "POST",
        headers: { "Authorization": "Bearer hg_key_123" },
        body: "{}",
      });

      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toBe("text/event-stream");
      expect(await res.text()).toBe("data: one\n\ndata: two\n\n");
    });

    it("rejects a missing bearer token with an OpenAI-shaped 401 without invoking the relay", async () => {
      let called = false;
      const url = await start({
        runExternalRelay: async (r) => {
          called = true;
          return okExternalRelay(r);
        },
      });

      const res = await fetch(`${url}/v1/chat/completions`, { method: "POST", body: "{}" });

      expect(res.status).toBe(401);
      const parsed = await res.json();
      expect(parsed.error.code).toBe("missing_api_key");
      expect(parsed.error.type).toBe("invalid_request_error");
      expect(called).toBe(false);
    });

    it("rejects an oversized body with 413", async () => {
      let called = false;
      const url = await start({
        maxBodyBytes: 64,
        runExternalRelay: async (r) => {
          called = true;
          return okExternalRelay(r);
        },
      });

      const res = await fetch(`${url}/v1/chat/completions`, {
        method: "POST",
        headers: { "Authorization": "Bearer hg_key_123" },
        body: JSON.stringify({ padding: "x".repeat(200) }),
      });

      expect(res.status).toBe(413);
      expect((await res.json()).error.code).toBe("request_too_large");
      expect(called).toBe(false);
    });

    it("rate limits per key with a Retry-After header", async () => {
      let calls = 0;
      const url = await start({
        rateLimiter: new RateLimiter({ perMinute: 1, perDay: 100 }),
        runExternalRelay: async (r) => {
          calls++;
          return okExternalRelay(r);
        },
      });

      const request = () =>
        fetch(`${url}/v1/chat/completions`, {
          method: "POST",
          headers: { "Authorization": "Bearer hg_key_123" },
          body: "{}",
        });

      expect((await request()).status).toBe(200);

      const limited = await request();
      expect(limited.status).toBe(429);
      expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
      expect((await limited.json()).error.code).toBe("rate_limit_exceeded");
      expect(calls).toBe(1);

      // A different key is unaffected.
      const other = await fetch(`${url}/v1/chat/completions`, {
        method: "POST",
        headers: { "Authorization": "Bearer hg_other_key" },
        body: "{}",
      });
      expect(other.status).toBe(200);
    });

    it("maps an external relay exception to an OpenAI-shaped 502", async () => {
      const url = await start({
        runExternalRelay: async () => {
          throw new Error("boom");
        },
      });

      const res = await fetch(`${url}/v1/chat/completions`, {
        method: "POST",
        headers: { "Authorization": "Bearer hg_key_123" },
        body: "{}",
      });

      expect(res.status).toBe(502);
      expect((await res.json()).error.code).toBe("gateway_error");
    });
  });
});
