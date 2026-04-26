/**
 * HTTP client for Harmonic Rails markdown API — Effect service.
 * Handles navigate (GET with Accept: text/markdown) and execute_action (POST).
 *
 * Agent requests go through ApplicationController like any external API client:
 * - URL is built with the tenant subdomain so Rails sees the right Host header
 * - TCP is routed to the Rails container via the RailsHttp dispatcher
 *   (see RailsHttp.ts for the full explanation of why the URL and TCP target
 *    are separated)
 * - Bearer token authenticates the agent as a user
 * - Subject to normal capability checks, API authorization, etc.
 *
 * X-Forwarded-Proto: https is set to prevent Rails' force_ssl from redirecting.
 * This is safe in production because the reverse proxy (Caddy) overwrites
 * X-Forwarded-Proto before forwarding to Rails, so external clients cannot
 * set this header to bypass SSL.
 */

import { Context, Effect, Layer } from "effect";
import { HarmonicApiError } from "../errors/Errors.js";
import { Config } from "../config/Config.js";
import { buildHeaders } from "./HmacSigner.js";
import { RailsHttp } from "./RailsHttp.js";

export interface NavigateResult {
  readonly content: string;
  readonly availableActions: readonly string[];
}

export interface ActionResult {
  readonly content: string;
  readonly success: boolean;
}

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
  readonly navigate: (path: string, token: string, subdomain: string) => Effect.Effect<NavigateResult, HarmonicApiError>;
  readonly executeAction: (
    path: string,
    action: string,
    params: Record<string, unknown> | undefined,
    token: string,
    subdomain: string,
  ) => Effect.Effect<ActionResult, HarmonicApiError>;
  readonly fetchChatHistory: (chatSessionId: string, subdomain: string) => Effect.Effect<ChatHistoryResponse, HarmonicApiError>;
}

export class HarmonicClient extends Context.Tag("HarmonicClient")<HarmonicClient, HarmonicClientService>() {}

/**
 * Parse available actions from YAML frontmatter in the markdown response.
 * Matches Ruby MarkdownUiService.parse_frontmatter + actions extraction.
 *
 * The Rails markdown layout wraps every response in frontmatter:
 * ---
 * actions:
 *   - name: create_note
 *     description: Create a note
 *     ...
 * ---
 */
export function parseAvailableActions(content: string): readonly string[] {
  // Must start with "---\n" (matches Ruby: content.start_with?("---\n"))
  if (!content.startsWith("---\n")) return [];

  // Find closing "---\n" after position 4 (matches Ruby: content.index("\n---\n", 4))
  const endIndex = content.indexOf("\n---\n", 4);
  if (endIndex === -1) return [];

  const frontmatter = content.slice(4, endIndex);

  // Parse action names from the YAML frontmatter.
  // We don't use a full YAML parser — just extract "- name: <value>" lines
  // within the "actions:" block.
  const actionsMatch = /^actions:\s*$/m.exec(frontmatter);
  if (actionsMatch === null) return [];

  const actionsBlock = frontmatter.slice(actionsMatch.index + actionsMatch[0].length);
  const names: string[] = [];

  for (const line of actionsBlock.split("\n")) {
    // Stop if we hit a non-indented line (next top-level YAML key)
    if (line.length > 0 && !line.startsWith(" ") && !line.startsWith("\t")) break;

    // Match only top-level action items (2-space indent: "  - name: value")
    // Skip deeper nested "name:" like params (6+ spaces)
    const nameMatch = /^  - name:\s*(.+)$/.exec(line);
    if (nameMatch?.[1] !== undefined) {
      const name = nameMatch[1].trim();
      if (name !== "") names.push(name);
    }
  }

  return names;
}

export const HarmonicClientLive = Layer.effect(
  HarmonicClient,
  Effect.gen(function* () {
    const railsHttp = yield* RailsHttp;
    const config = yield* Config;

    const navigate: HarmonicClientService["navigate"] = (path, token, subdomain) =>
      Effect.tryPromise({
        try: async () => {
          const response = await railsHttp.request({
            method: "GET",
            subdomain,
            path,
            headers: {
              "X-Forwarded-Proto": "https",
              "Accept": "text/markdown",
              "Authorization": `Bearer ${token}`,
            },
            timeoutMs: 30_000,
          });

          const content = await response.text();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw new Error(`Navigate to ${path} failed: HTTP ${response.statusCode} - ${content.slice(0, 500)}`);
          }
          const availableActions = parseAvailableActions(content);

          return { content, availableActions };
        },
        catch: (error) =>
          new HarmonicApiError({
            message: error instanceof Error ? error.message : String(error),
            path,
          }),
      });

    const executeAction: HarmonicClientService["executeAction"] = (path, action, params, token, subdomain) =>
      Effect.tryPromise({
        try: async () => {
          const response = await railsHttp.request({
            method: "POST",
            subdomain,
            path: `${path}/actions/${action}`,
            headers: {
              "X-Forwarded-Proto": "https",
              "Content-Type": "application/json",
              "Accept": "text/markdown",
              "Authorization": `Bearer ${token}`,
            },
            body: params !== undefined ? JSON.stringify(params) : "{}",
            timeoutMs: 30_000,
          });

          const content = await response.text();
          return {
            content,
            success: response.statusCode >= 200 && response.statusCode < 300,
          };
        },
        catch: (error) =>
          new HarmonicApiError({
            message: error instanceof Error ? error.message : String(error),
            path: `${path}/actions/${action}`,
          }),
      });

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

    return { navigate, executeAction, fetchChatHistory };
  }),
);
