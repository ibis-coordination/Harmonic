/**
 * HTTP request handling for the gateway, decoupled from the Effect runtime so
 * the routing contract can be tested without a live Stripe/Rails stack.
 *
 * Two ingress lanes, routed by path:
 *
 *   POST /chat/completions     — internal relay (agent-runner). No auth of its
 *                                own: network isolation is the auth, and the
 *                                edge proxy forwards only /v1/* so this path
 *                                is unreachable from outside.
 *   POST /v1/chat/completions  — external ingress (agents calling with their
 *                                llm_gateway API keys via llm.<hostname>).
 *                                Bearer-authenticated by Rails per call; size
 *                                caps and per-key rate limits apply here.
 *
 * The relays are injected as plain async functions — {@link server.ts} wires
 * in the real Effect runtime; tests wire in fakes.
 */

import type { IncomingMessage, ServerResponse } from "node:http";
import { Readable } from "node:stream";
import { createHash } from "node:crypto";
import type { GatewayRelayRequest, GatewayRelayResult } from "./Relay.js";
import type { ExternalRelayRequest, ExternalRelayResult } from "./ExternalRelay.js";
import type { RateLimiter } from "./RateLimiter.js";
import { log } from "../services/Logger.js";

export type RelayRunner = (req: GatewayRelayRequest) => Promise<GatewayRelayResult>;
export type ExternalRelayRunner = (req: ExternalRelayRequest) => Promise<ExternalRelayResult>;

export interface GatewayHandlerDeps {
  readonly runRelay: RelayRunner;
  readonly runExternalRelay: ExternalRelayRunner;
  readonly rateLimiter: RateLimiter;
  readonly maxBodyBytes: number;
}

/** Sentinel for a body that exceeded maxBytes. */
const OVERSIZED = Symbol("oversized");

const readBody = (req: IncomingMessage, maxBytes: number): Promise<string | typeof OVERSIZED> =>
  new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    req.on("data", (chunk: Buffer) => {
      total += chunk.length;
      if (total > maxBytes) {
        // Drain (not destroy) so the 413 response can still flush; the
        // response carries Connection: close to stop a client that keeps
        // uploading.
        req.removeAllListeners("data");
        req.resume();
        resolve(OVERSIZED);
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });

const header = (req: IncomingMessage, name: string): string | undefined => {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
};

const sendJson = (res: ServerResponse, status: number, body: string, headers?: Record<string, string>): void => {
  res.writeHead(status, { "Content-Type": "application/json", ...(headers ?? {}) });
  res.end(body);
};

const openAiError = (code: string, message: string): string =>
  JSON.stringify({ error: { message, type: "invalid_request_error", code } });

const sendExternalResult = (res: ServerResponse, result: ExternalRelayResult): void => {
  res.writeHead(result.status, { "Content-Type": result.contentType });
  if (typeof result.body === "string") {
    res.end(result.body);
    return;
  }
  // Pipe upstream bytes through as they arrive — this is what makes SSE
  // streaming work end to end.
  Readable.fromWeb(result.body as import("node:stream/web").ReadableStream<Uint8Array>).pipe(res);
};

const handleInternal = async (
  req: IncomingMessage,
  res: ServerResponse,
  deps: GatewayHandlerDeps,
): Promise<void> => {
  const taskRunId = header(req, "x-harmonic-task-run-id");
  const subdomain = header(req, "x-harmonic-subdomain");
  const model = header(req, "x-harmonic-model") ?? "";
  if (taskRunId === undefined || taskRunId === "" || subdomain === undefined || subdomain === "") {
    sendJson(res, 400, JSON.stringify({ error: "missing_routing_headers" }));
    return;
  }

  try {
    const body = await readBody(req, deps.maxBodyBytes);
    if (body === OVERSIZED) {
      sendJson(res, 413, JSON.stringify({ error: "request_too_large" }), { "Connection": "close" });
      return;
    }
    const result = await deps.runRelay({ taskRunId, subdomain, model, body });
    sendJson(res, result.status, result.body);
  } catch (error) {
    log.error({
      event: "gateway_relay_error",
      task_run_id: taskRunId,
      message: error instanceof Error ? error.message : String(error),
    });
    sendJson(res, 502, JSON.stringify({ error: "gateway_error" }));
  }
};

const handleExternal = async (
  req: IncomingMessage,
  res: ServerResponse,
  deps: GatewayHandlerDeps,
): Promise<void> => {
  const authorization = header(req, "authorization") ?? "";
  const bearerToken = authorization.startsWith("Bearer ") ? authorization.slice("Bearer ".length).trim() : "";
  if (bearerToken === "") {
    sendJson(res, 401, openAiError("missing_api_key", "Pass your llm_gateway API key as a Bearer token."));
    return;
  }

  // Rate limit before any body read or Rails/Stripe work. The bucket is keyed
  // by a hash so raw keys are never retained in limiter memory.
  const limit = deps.rateLimiter.check(createHash("sha256").update(bearerToken).digest("hex"));
  if (!limit.allowed) {
    sendJson(
      res,
      429,
      openAiError("rate_limit_exceeded", "Rate limit exceeded. Retry after the indicated delay."),
      { "Retry-After": String(limit.retryAfterSeconds) },
    );
    return;
  }

  try {
    const body = await readBody(req, deps.maxBodyBytes);
    if (body === OVERSIZED) {
      sendJson(res, 413, openAiError("request_too_large", "Request body exceeds the gateway's size limit."), {
        "Connection": "close",
      });
      return;
    }
    const result = await deps.runExternalRelay({ bearerToken, body });
    sendExternalResult(res, result);
  } catch (error) {
    log.error({
      event: "gateway_external_relay_error",
      message: error instanceof Error ? error.message : String(error),
    });
    sendJson(res, 502, openAiError("gateway_error", "The gateway could not complete the request."));
  }
};

export const createHandler =
  (deps: GatewayHandlerDeps) =>
  async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    if (req.method === "GET" && req.url === "/health") {
      sendJson(res, 200, JSON.stringify({ status: "ok" }));
      return;
    }
    if (req.method !== "POST") {
      sendJson(res, 405, JSON.stringify({ error: "method_not_allowed" }));
      return;
    }

    if (req.url === "/v1/chat/completions") {
      await handleExternal(req, res, deps);
      return;
    }
    await handleInternal(req, res, deps);
  };
