/**
 * LLM Gateway — HTTP entry point.
 *
 * A small HTTP server that fronts the {@link relay}. Callers (today the
 * agent-runner) POST an OpenAI chat-completions body plus routing headers:
 *
 *   X-Harmonic-Task-Run-Id  — the task run behind the call (payer resolution)
 *   X-Harmonic-Subdomain    — tenant subdomain (Host for the internal Rails call)
 *   X-Harmonic-Model        — model name, for logging only
 *
 * The request body is forwarded to the Stripe AI Gateway verbatim; the upstream
 * response is returned unchanged so the caller parses it exactly as it would a
 * direct Stripe response. The service is internal-only: backend network, no
 * public route, no published port.
 */

import { createServer } from "node:http";
import { Layer, ManagedRuntime } from "effect";
import { ConfigLive } from "../config/Config.js";
import { RailsHttpLive } from "../services/RailsHttp.js";
import { StripeUpstreamLive } from "./StripeUpstream.js";
import { relay } from "./Relay.js";
import { createHandler } from "./handler.js";
import { log } from "../services/Logger.js";

// Fail fast on the misconfiguration that would otherwise 502 every relay: the
// gateway's entire job is to reach the Stripe AI Gateway with this key.
if (process.env["STRIPE_GATEWAY_KEY"] === undefined || process.env["STRIPE_GATEWAY_KEY"] === "") {
  log.error({ event: "gateway_misconfigured", message: "STRIPE_GATEWAY_KEY is required" });
  process.exit(1);
}

const AppLayer = Layer.provideMerge(
  Layer.mergeAll(RailsHttpLive, StripeUpstreamLive),
  ConfigLive,
);
const runtime = ManagedRuntime.make(AppLayer);

const handler = createHandler((req) => runtime.runPromise(relay(req)));

const port = parseInt(process.env["GATEWAY_PORT"] ?? "4500", 10) || 4500;
const server = createServer((req, res) => {
  void handler(req, res);
});

server.listen(port, () => {
  log.info({ event: "gateway_listening", port });
});

const shutdown = (signal: string): void => {
  log.info({ event: "gateway_shutdown", signal });
  server.close(() => {
    void runtime.dispose().finally(() => process.exit(0));
  });
};
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
