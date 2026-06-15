/**
 * HMAC-authenticated Harmonic Rails client — Effect service.
 *
 * Holds runner ↔ Rails calls that aren't agent-acting and therefore don't go
 * through /mcp. Today that's just fetchChatHistory: the runner fetches prior
 * messages from /internal/agent-runner/chat/{session_id}/history when
 * preparing the system prompt for a chat turn. The agent itself never
 * invokes this — it's runner-side setup.
 *
 * Agent-acting calls (fetch_page, execute_action) live on McpClient and use
 * the public /mcp endpoint with Bearer auth.
 */

import { Context, Effect, Layer } from "effect";
import { HarmonicApiError } from "../errors/Errors.js";
import { Config } from "../config/Config.js";
import { buildHeaders } from "./HmacSigner.js";
import { RailsHttp } from "./RailsHttp.js";

export interface ChatHistoryMessage {
  readonly content: string;
  readonly sender_id?: string;
  readonly sender_name?: string;
  readonly role: "user" | "assistant" | "system";
  readonly timestamp: string;
}

export interface ChatHistoryResponse {
  readonly messages: readonly ChatHistoryMessage[];
  readonly current_state: {
    readonly current_path?: string;
  };
}

export interface HarmonicClientService {
  readonly fetchChatHistory: (chatSessionId: string, subdomain: string) => Effect.Effect<ChatHistoryResponse, HarmonicApiError>;
}

export class HarmonicClient extends Context.Tag("HarmonicClient")<HarmonicClient, HarmonicClientService>() {}

export const HarmonicClientLive = Layer.effect(
  HarmonicClient,
  Effect.gen(function* () {
    const railsHttp = yield* RailsHttp;
    const config = yield* Config;

    const fetchChatHistory: HarmonicClientService["fetchChatHistory"] = (chatSessionId, subdomain) => {
      const path = `/internal/agent-runner/chat/${chatSessionId}/history`;
      const hmacHeaders = buildHeaders("", config.agentRunnerSecret);

      return Effect.tryPromise({
        try: async () => {
          const response = await railsHttp.request({
            method: "GET",
            subdomain,
            path,
            headers: { ...hmacHeaders },
            timeoutMs: 10_000,
          });

          const text = await response.text();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw new Error(`Chat history fetch failed: HTTP ${response.statusCode} - ${text.slice(0, 500)}`);
          }
          const data = JSON.parse(text) as ChatHistoryResponse;
          return data;
        },
        catch: (error) =>
          new HarmonicApiError({
            message: error instanceof Error ? error.message : String(error),
            path,
          }),
      });
    };

    return { fetchChatHistory };
  }),
);
