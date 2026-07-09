/**
 * HTTP request handling for the gateway, decoupled from the Effect runtime so
 * the routing-header contract can be tested without a live Stripe/Rails stack.
 *
 * The relay itself is injected as a plain async function — {@link server.ts}
 * wires in the real Effect runtime; tests wire in a fake.
 */

import type { IncomingMessage, ServerResponse } from "node:http";
import type { GatewayRelayRequest, GatewayRelayResult } from "./Relay.js";
import { log } from "../services/Logger.js";

export type RelayRunner = (req: GatewayRelayRequest) => Promise<GatewayRelayResult>;

const readBody = (req: IncomingMessage): Promise<string> =>
  new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });

const header = (req: IncomingMessage, name: string): string | undefined => {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
};

const sendJson = (res: ServerResponse, status: number, body: string): void => {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(body);
};

export const createHandler =
  (runRelay: RelayRunner) =>
  async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    if (req.method === "GET" && req.url === "/health") {
      sendJson(res, 200, JSON.stringify({ status: "ok" }));
      return;
    }
    if (req.method !== "POST") {
      sendJson(res, 405, JSON.stringify({ error: "method_not_allowed" }));
      return;
    }

    const taskRunId = header(req, "x-harmonic-task-run-id");
    const subdomain = header(req, "x-harmonic-subdomain");
    const model = header(req, "x-harmonic-model") ?? "";
    if (taskRunId === undefined || taskRunId === "" || subdomain === undefined || subdomain === "") {
      sendJson(res, 400, JSON.stringify({ error: "missing_routing_headers" }));
      return;
    }

    try {
      const body = await readBody(req);
      const result = await runRelay({ taskRunId, subdomain, model, body });
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
