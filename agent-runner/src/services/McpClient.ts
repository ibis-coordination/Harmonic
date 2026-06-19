/**
 * MCP (Model Context Protocol) client for agent-acting calls — Effect service.
 *
 * Speaks the JSON-RPC 2.0 envelope for the 2025-11-25 revision of the
 * Streamable HTTP transport. Each call is a stateless one-shot `POST /mcp`
 * with `Authorization: Bearer …` and `MCP-Protocol-Version: 2025-11-25`. No
 * `initialize` handshake, no `MCP-Session-Id` — matches the hosted endpoint's
 * stateless design.
 *
 * Replaces HarmonicClient.navigate / executeAction. HarmonicClient survives
 * with only fetchChatHistory, which pulls chat-session context the runner
 * uses to build the LLM prompt; it stays on the HMAC `/internal/...` path
 * because it isn't a tool the agent invokes.
 *
 * Why no @modelcontextprotocol/sdk
 * --------------------------------
 * The SDK is built around long-lived stateful client sessions with SSE
 * resumption. Our use case is the opposite: one-shot stateless calls
 * authenticated by Bearer per request. The JSON-RPC envelope is small and
 * fully under our control (we wrote both sides). A dependency-free
 * implementation keeps the call site shape obvious and avoids the SDK's
 * session-management ceremony.
 */

import { Context, Effect, Layer } from "effect";
import { HarmonicApiError } from "../errors/Errors.js";
import { RailsHttp, type RailsResponse } from "./RailsHttp.js";
import { withRetryAfter, type RetryBudget } from "./Retry.js";
import { parseAvailableActions, parseResolvedPath } from "../core/MarkdownFrontmatter.js";

const MCP_PROTOCOL_VERSION = "2025-11-25";

export interface FetchPageResult {
  readonly content: string;
  readonly availableActions: readonly string[];
  readonly resolvedPath: string;
  readonly mcpToolCallLogId: string | null;
}

export interface ExecuteActionResult {
  readonly content: string;
  readonly success: boolean;
  readonly mcpToolCallLogId: string | null;
}

export interface McpClientService {
  readonly fetchPage: (
    path: string,
    token: string,
    subdomain: string,
    retryBudget: RetryBudget,
  ) => Effect.Effect<FetchPageResult, HarmonicApiError>;
  readonly executeAction: (
    context: Record<string, unknown>,
    path: string,
    action: string,
    params: Record<string, unknown> | undefined,
    token: string,
    subdomain: string,
    retryBudget: RetryBudget,
  ) => Effect.Effect<ExecuteActionResult, HarmonicApiError>;
}

export class McpClient extends Context.Tag("McpClient")<McpClient, McpClientService>() {}

interface JsonRpcResponse {
  readonly jsonrpc: string;
  readonly id?: number | string | null;
  readonly result?: {
    readonly content?: ReadonlyArray<{ readonly type: string; readonly text?: string }>;
    readonly isError?: boolean;
    readonly _meta?: { readonly harmonic?: { readonly tool_call_log_id?: string } };
  };
  readonly error?: { readonly code: number; readonly message: string; readonly data?: unknown };
}

export const McpClientLive = Layer.effect(
  McpClient,
  Effect.gen(function* () {
    const railsHttp = yield* RailsHttp;

    let requestIdCounter = 0;
    const nextId = (): number => ++requestIdCounter;

    const post = async (
      subdomain: string,
      token: string,
      body: object,
      retryBudget: RetryBudget,
    ): Promise<RailsResponse> => withRetryAfter(retryBudget, () => railsHttp.request({
      method: "POST",
      subdomain,
      path: "/mcp",
      headers: {
        "X-Forwarded-Proto": "https",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": `Bearer ${token}`,
        "MCP-Protocol-Version": MCP_PROTOCOL_VERSION,
      },
      body: JSON.stringify(body),
      timeoutMs: 30_000,
    }));

    const callTool = async (
      name: string,
      args: Record<string, unknown>,
      token: string,
      subdomain: string,
      retryBudget: RetryBudget,
    ): Promise<JsonRpcResponse> => {
      const envelope = {
        jsonrpc: "2.0",
        id: nextId(),
        method: "tools/call",
        params: { name, arguments: args },
      };
      const response = await post(subdomain, token, envelope, retryBudget);
      const text = await response.text();
      if (response.statusCode === 401) {
        throw new Error(`MCP call unauthorized (token revoked or expired)`);
      }
      if (response.statusCode === 429) {
        throw new Error(`MCP call rate-limited after backoff: ${text.slice(0, 200)}`);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error(`MCP call failed: HTTP ${response.statusCode} - ${text.slice(0, 500)}`);
      }
      return JSON.parse(text) as JsonRpcResponse;
    };

    const extractResultText = (rpc: JsonRpcResponse): string => {
      const first = rpc.result?.content?.[0];
      return first?.text ?? "";
    };

    const extractLogId = (rpc: JsonRpcResponse): string | null =>
      rpc.result?._meta?.harmonic?.tool_call_log_id ?? null;

    const fetchPage: McpClientService["fetchPage"] = (path, token, subdomain, retryBudget) =>
      Effect.tryPromise({
        try: async () => {
          const rpc = await callTool("fetch_page", { path }, token, subdomain, retryBudget);
          if (rpc.error !== undefined) {
            throw new Error(`fetch_page JSON-RPC error: ${rpc.error.message}`);
          }
          const content = extractResultText(rpc);
          const isError = rpc.result?.isError ?? false;
          // fetchPage throws on tool error (executeAction returns success: false
          // instead) because fetchPage's downstream contract includes
          // `availableActions` and `resolvedPath` parsed from the markdown
          // frontmatter — those fields don't exist on a 4xx body. Throwing keeps
          // the loop on the error-recording path rather than handing back a
          // structurally-incomplete result.
          if (isError) {
            throw new Error(`fetch_page tool error: ${content.slice(0, 500)}`);
          }
          return {
            content,
            availableActions: parseAvailableActions(content),
            resolvedPath: parseResolvedPath(content) ?? path,
            mcpToolCallLogId: extractLogId(rpc),
          };
        },
        catch: (error) =>
          new HarmonicApiError({
            message: error instanceof Error ? error.message : String(error),
            path,
          }),
      });

    const executeAction: McpClientService["executeAction"] = (context, path, action, params, token, subdomain, retryBudget) =>
      Effect.tryPromise({
        try: async () => {
          const args = { context, path, action, ...(params !== undefined ? { params } : {}) };
          const rpc = await callTool("execute_action", args, token, subdomain, retryBudget);
          if (rpc.error !== undefined) {
            throw new Error(`execute_action JSON-RPC error: ${rpc.error.message}`);
          }
          const content = extractResultText(rpc);
          const isError = rpc.result?.isError ?? false;
          return {
            content,
            success: !isError,
            mcpToolCallLogId: extractLogId(rpc),
          };
        },
        catch: (error) =>
          new HarmonicApiError({
            message: error instanceof Error ? error.message : String(error),
            path: `${path}/actions/${action}`,
          }),
      });

    return { fetchPage, executeAction };
  }),
);
