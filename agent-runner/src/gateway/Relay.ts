/**
 * Gateway relay — the core of the LLM gateway.
 *
 * For one billed LLM call: resolve the payer via Rails `select-payer`, then
 * forward the request body to the Stripe AI Gateway with that customer's
 * billing header. The upstream response is returned verbatim so the caller
 * (today the agent-runner's LLMClient) parses it exactly as it would a direct
 * Stripe response. The gateway itself stays a dumb, stateless relay.
 */

import { Effect } from "effect";
import { Config } from "../config/Config.js";
import { RailsHttp } from "../services/RailsHttp.js";
import { StripeUpstream } from "./StripeUpstream.js";
import { buildHeaders } from "../services/HmacSigner.js";
import { extractUsageFromJson, reportUsage } from "./UsageReporter.js";
import { GatewayError } from "../errors/Errors.js";
import { log } from "../services/Logger.js";

const SELECT_PAYER_PATH = "/internal/llm-gateway/select-payer";

export interface GatewayRelayRequest {
  /** Task run behind this LLM call — the payer is resolved from it. */
  readonly taskRunId: string;
  /** Tenant subdomain, used as the Host for the internal Rails call. */
  readonly subdomain: string;
  /** Model name, for logging only (the body carries the authoritative model). */
  readonly model: string;
  /** Raw OpenAI chat-completions JSON to forward to Stripe verbatim. */
  readonly body: string;
}

export interface GatewayRelayResult {
  readonly status: number;
  readonly body: string;
}

export const relay = (
  req: GatewayRelayRequest,
): Effect.Effect<GatewayRelayResult, GatewayError, Config | RailsHttp | StripeUpstream> =>
  Effect.gen(function* () {
    const config = yield* Config;
    const rails = yield* RailsHttp;
    const stripe = yield* StripeUpstream;

    // 1. Resolve the payer (and funding) from Rails.
    const selectBody = JSON.stringify({ task_run_id: req.taskRunId });
    const selectResponse = yield* Effect.tryPromise({
      try: () =>
        rails.request({
          method: "POST",
          subdomain: req.subdomain,
          path: SELECT_PAYER_PATH,
          headers: buildHeaders(selectBody, config.agentRunnerSecret),
          body: selectBody,
          // Keep this hop short: it's a local DB lookup, and its budget adds
          // to the Stripe upstream's 120s. The caller's own timeout must
          // exceed the sum (see LLMClient), or a slow-but-successful billed
          // call gets aborted client-side after Stripe has already metered it.
          timeoutMs: 10_000,
        }),
      catch: (error) =>
        new GatewayError({ message: `select-payer request failed: ${error instanceof Error ? error.message : String(error)}` }),
    });
    const selectText = yield* Effect.promise(() => selectResponse.text());

    // Propagate a payer-resolution failure (not_funded, not_a_billed_task,
    // not found, …) verbatim without spending an LLM call.
    if (selectResponse.statusCode !== 200) {
      log.warn({
        event: "select_payer_rejected",
        task_run_id: req.taskRunId,
        status_code: selectResponse.statusCode,
      });
      return { status: selectResponse.statusCode, body: selectText };
    }

    const parsed = yield* Effect.try({
      try: () => JSON.parse(selectText) as { payer_customer_id?: string; selection_id?: string | null },
      catch: () => new GatewayError({ message: "select-payer returned a non-JSON 200 body" }),
    });
    const payerCustomerId = parsed.payer_customer_id;
    if (payerCustomerId === undefined || payerCustomerId === "") {
      return yield* Effect.fail(new GatewayError({ message: "select-payer returned no payer_customer_id" }));
    }

    // 2. Forward to the Stripe AI Gateway with the billing header.
    const startedAt = Date.now();
    const upstream = yield* Effect.tryPromise({
      try: () => stripe.chatCompletions({ customerId: payerCustomerId, body: req.body }),
      catch: (error) =>
        new GatewayError({ message: `stripe upstream failed: ${error instanceof Error ? error.message : String(error)}` }),
    });

    // Routing/observability only — never the customer id or prompt content.
    log.info({
      event: "llm_request",
      gateway_mode: "stripe_gateway",
      model: req.model,
      status_code: upstream.status,
      duration_ms: Date.now() - startedAt,
    });

    // Close out the ledger row select-payer opened. Fire-and-forget: the
    // caller already has its response; a successful call whose body somehow
    // carries no usage stays pending rather than being faked as free.
    // Rails renders selection_id: null when opening the ledger row failed.
    const selectionId = parsed.selection_id;
    if (typeof selectionId === "string" && selectionId !== "") {
      const ok = upstream.status === 200;
      const usage = ok ? extractUsageFromJson(upstream.body) : null;
      if (!ok || usage !== null) {
        void reportUsage(rails, config.agentRunnerSecret, {
          subdomain: req.subdomain,
          selectionId,
          model: req.model,
          usage,
          ok,
        });
      }
    }

    return { status: upstream.status, body: upstream.body };
  });
