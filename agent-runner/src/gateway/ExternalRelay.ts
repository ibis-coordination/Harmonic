/**
 * External relay — the gateway's public ingress flow.
 *
 * An external agent calls the OpenAI-compatible /v1/chat/completions with its
 * llm_gateway API key as the Bearer token. Rails authenticates the key and
 * resolves the payer via `select-payer-for-token` (the key says WHO calls;
 * the agent's own pool/billing mapping says WHO PAYS); the relay then forwards
 * the body — model rewritten to the mapped name — to the Stripe AI Gateway and
 * streams the response back verbatim. Rails error bodies are OpenAI-shaped and
 * pass through to the client unchanged.
 */

import { Effect } from "effect";
import { Config } from "../config/Config.js";
import { RailsHttp } from "../services/RailsHttp.js";
import { StripeUpstream } from "./StripeUpstream.js";
import { buildHeaders } from "../services/HmacSigner.js";
import { GatewayError } from "../errors/Errors.js";
import { log } from "../services/Logger.js";

const SELECT_PAYER_FOR_TOKEN_PATH = "/internal/llm-gateway/select-payer-for-token";

export interface ExternalRelayRequest {
  /** The caller's llm_gateway API key. Never logged. */
  readonly bearerToken: string;
  /** Raw OpenAI chat-completions JSON from the external client. */
  readonly body: string;
}

export interface ExternalRelayResult {
  readonly status: number;
  readonly contentType: string;
  /** A stream for upstream responses; a string for locally-produced errors and passthroughs. */
  readonly body: string | ReadableStream<Uint8Array>;
}

const openAiError = (status: number, code: string, message: string): ExternalRelayResult => ({
  status,
  contentType: "application/json",
  body: JSON.stringify({ error: { message, type: "invalid_request_error", code } }),
});

export const externalRelay = (
  req: ExternalRelayRequest,
): Effect.Effect<ExternalRelayResult, GatewayError, Config | RailsHttp | StripeUpstream> =>
  Effect.gen(function* () {
    const config = yield* Config;
    const rails = yield* RailsHttp;
    const stripe = yield* StripeUpstream;

    let parsed: Record<string, unknown>;
    try {
      const value: unknown = JSON.parse(req.body);
      if (typeof value !== "object" || value === null || Array.isArray(value)) {
        return openAiError(400, "invalid_json", "Request body must be a JSON object.");
      }
      parsed = value as Record<string, unknown>;
    } catch {
      return openAiError(400, "invalid_json", "Request body is not valid JSON.");
    }
    const requestedModel = typeof parsed["model"] === "string" ? parsed["model"] : undefined;

    // 1. Authenticate the key and resolve the payer + mapped model via Rails.
    const selectBody = JSON.stringify(
      requestedModel === undefined
        ? { agent_token: req.bearerToken }
        : { agent_token: req.bearerToken, model: requestedModel },
    );
    const selectResponse = yield* Effect.tryPromise({
      try: () =>
        rails.request({
          method: "POST",
          subdomain: config.primarySubdomain,
          path: SELECT_PAYER_FOR_TOKEN_PATH,
          headers: buildHeaders(selectBody, config.agentRunnerSecret),
          body: selectBody,
          // Short hop, same budget reasoning as the internal relay: this plus
          // the Stripe upstream's 120s must stay under the client's timeout.
          timeoutMs: 10_000,
        }),
      catch: (error) =>
        new GatewayError({ message: `select-payer-for-token request failed: ${error instanceof Error ? error.message : String(error)}` }),
    });
    const selectText = yield* Effect.promise(() => selectResponse.text());

    // Pass auth/flag/funding/model rejections through verbatim (the bodies
    // are already OpenAI-shaped) without spending an LLM call.
    if (selectResponse.statusCode !== 200) {
      log.warn({
        event: "select_payer_for_token_rejected",
        status_code: selectResponse.statusCode,
      });
      return { status: selectResponse.statusCode, contentType: "application/json", body: selectText };
    }

    const selectParsed = yield* Effect.try({
      try: () => JSON.parse(selectText) as { payer_customer_id?: string; model?: string },
      catch: () => new GatewayError({ message: "select-payer-for-token returned a non-JSON 200 body" }),
    });
    const payerCustomerId = selectParsed.payer_customer_id;
    if (payerCustomerId === undefined || payerCustomerId === "") {
      return yield* Effect.fail(new GatewayError({ message: "select-payer-for-token returned no payer_customer_id" }));
    }
    const mappedModel = selectParsed.model;

    // 2. Forward to the Stripe AI Gateway with the model Rails resolved
    // (blank/"default" maps to the canonical default) and stream the
    // response back.
    if (mappedModel !== undefined) {
      parsed["model"] = mappedModel;
    }
    const startedAt = Date.now();
    const upstream = yield* Effect.tryPromise({
      try: () => stripe.chatCompletionsStream({ customerId: payerCustomerId, body: JSON.stringify(parsed) }),
      catch: (error) =>
        new GatewayError({ message: `stripe upstream failed: ${error instanceof Error ? error.message : String(error)}` }),
    });

    // Routing/observability only — never the key, customer id, or prompt
    // content. Status/duration are as-of response headers; streamed bodies
    // finish later.
    log.info({
      event: "llm_request_external",
      gateway_mode: "stripe_gateway",
      model: mappedModel ?? requestedModel ?? "",
      status_code: upstream.status,
      duration_ms: Date.now() - startedAt,
    });

    return { status: upstream.status, contentType: upstream.contentType, body: upstream.body ?? "" };
  });
