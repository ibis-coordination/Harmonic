import { describe, it, expect } from "vitest";
import { Effect, Layer, Exit } from "effect";
import {
  McpClient,
  McpClientLive,
  type FetchPageResult,
  type ExecuteActionResult,
} from "../../src/services/McpClient.js";
import { RailsHttp, type RailsRequestOptions, type RailsResponse } from "../../src/services/RailsHttp.js";
import { Config } from "../../src/config/Config.js";
import { createRetryBudget } from "../../src/services/Retry.js";
import type { HarmonicApiError } from "../../src/errors/Errors.js";

const TEST_CONFIG = {
  harmonicInternalUrl: "http://web:3000",
  harmonicHostname: "harmonic.local",
  agentRunnerSecret: "test-secret",
  redisUrl: "redis://localhost:6379",
  llmBaseUrl: "http://localhost:4000",
  llmGatewayMode: "litellm" as const,
  stripeGatewayKey: undefined,
  streamName: "agent_tasks",
  consumerGroup: "agent_runners",
  consumerName: "test",
  maxConcurrentTasks: 1,
  streamMaxLen: 1000,
};

function makeResponse(statusCode: number, body: string, headers: Record<string, string> = {}): RailsResponse {
  return { statusCode, headers, text: async () => body };
}

function makeMcpEnvelope(opts: {
  content?: string;
  isError?: boolean;
  toolCallLogId?: string;
  errorMessage?: string;
}): string {
  if (opts.errorMessage !== undefined) {
    return JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      error: { code: -32601, message: opts.errorMessage },
    });
  }
  return JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    result: {
      content: [{ type: "text", text: opts.content ?? "" }],
      isError: opts.isError ?? false,
      _meta: opts.toolCallLogId !== undefined
        ? { harmonic: { tool_call_log_id: opts.toolCallLogId } }
        : undefined,
    },
  });
}

function buildLayer(handler: (opts: RailsRequestOptions) => RailsResponse) {
  const RailsHttpTest = Layer.succeed(RailsHttp, {
    request: async (opts: RailsRequestOptions) => handler(opts),
  });
  const ConfigTest = Layer.succeed(Config, TEST_CONFIG);
  return McpClientLive.pipe(Layer.provide(Layer.merge(RailsHttpTest, ConfigTest)));
}

function runFetchPage(
  handler: (opts: RailsRequestOptions) => RailsResponse,
  path: string,
  context?: Record<string, unknown>,
): Promise<Exit.Exit<FetchPageResult, HarmonicApiError>> {
  const program = Effect.gen(function* () {
    const client = yield* McpClient;
    return yield* client.fetchPage(path, context, "tok", "app", createRetryBudget());
  });
  return Effect.runPromiseExit(program.pipe(Effect.provide(buildLayer(handler))));
}

const TEST_CONTEXT: Record<string, unknown> = {
  identity: { actor: "@test-agent" },
  visibility: "shared",
  intention: "run a test",
};

function runExecuteAction(
  handler: (opts: RailsRequestOptions) => RailsResponse,
  path: string,
  action: string,
  params: Record<string, unknown> = {},
  context: Record<string, unknown> = TEST_CONTEXT,
): Promise<Exit.Exit<ExecuteActionResult, HarmonicApiError>> {
  const program = Effect.gen(function* () {
    const client = yield* McpClient;
    return yield* client.executeAction(context, path, action, params, "tok", "app", createRetryBudget());
  });
  return Effect.runPromiseExit(program.pipe(Effect.provide(buildLayer(handler))));
}

const MARKDOWN_PAGE = `---
app: Harmonic
path: /whoami
title: Who Am I?
actions:
  - name: update_scratchpad
    description: Update your scratchpad
---
# Body content here
`;

describe("McpClient.fetchPage", () => {
  it("returns markdown content with parsed availableActions and resolvedPath from frontmatter", async () => {
    const handler = (opts: RailsRequestOptions) => {
      expect(opts.method).toBe("POST");
      expect(opts.path).toBe("/mcp");
      expect(opts.headers?.["Authorization"]).toBe("Bearer tok");
      expect(opts.headers?.["MCP-Protocol-Version"]).toBe("2025-11-25");
      const payload = JSON.parse(opts.body ?? "{}");
      expect(payload.method).toBe("tools/call");
      expect(payload.params.name).toBe("fetch_page");
      expect(payload.params.arguments.path).toBe("/whoami");
      // No context declared → no context field on the wire.
      expect(payload.params.arguments.context).toBeUndefined();
      return makeResponse(200, makeMcpEnvelope({
        content: MARKDOWN_PAGE,
        toolCallLogId: "log-abc",
      }));
    };
    const exit = await runFetchPage(handler, "/whoami");
    expect(Exit.isSuccess(exit)).toBe(true);
    if (Exit.isSuccess(exit)) {
      expect(exit.value.content).toBe(MARKDOWN_PAGE);
      expect(exit.value.availableActions).toEqual(["update_scratchpad"]);
      expect(exit.value.resolvedPath).toBe("/whoami");
      expect(exit.value.mcpToolCallLogId).toBe("log-abc");
    }
  });

  it("threads the optional context block on the wire when representing", async () => {
    const ctx = {
      identity: { viewer: "@agent-bob", viewing_as: "@alice" },
      representation_session_id: "abc12345",
    };
    let observedContext: unknown;
    const handler = (opts: RailsRequestOptions) => {
      const payload = JSON.parse(opts.body ?? "{}");
      observedContext = payload.params.arguments.context;
      return makeResponse(200, makeMcpEnvelope({ content: MARKDOWN_PAGE }));
    };
    const exit = await runFetchPage(handler, "/whoami", ctx);
    expect(Exit.isSuccess(exit)).toBe(true);
    expect(observedContext).toEqual(ctx);
  });

  it("falls back to the requested path when frontmatter has no path: line", async () => {
    const noPath = "---\napp: Harmonic\n---\n# Hi";
    const handler = () => makeResponse(200, makeMcpEnvelope({ content: noPath }));
    const exit = await runFetchPage(handler, "/requested");
    expect(Exit.isSuccess(exit)).toBe(true);
    if (Exit.isSuccess(exit)) {
      expect(exit.value.resolvedPath).toBe("/requested");
    }
  });

  it("surfaces JSON-RPC errors as HarmonicApiError", async () => {
    const handler = () => makeResponse(200, makeMcpEnvelope({ errorMessage: "Method not found" }));
    const exit = await runFetchPage(handler, "/whoami");
    expect(Exit.isFailure(exit)).toBe(true);
  });

  it("surfaces 401 (revoked token) as HarmonicApiError", async () => {
    const handler = () => makeResponse(401, "Unauthorized");
    const exit = await runFetchPage(handler, "/whoami");
    expect(Exit.isFailure(exit)).toBe(true);
    if (Exit.isFailure(exit)) {
      const message = JSON.stringify(exit.cause);
      expect(message).toMatch(/unauthorized/i);
    }
  });

  it("surfaces tool isError envelope as HarmonicApiError", async () => {
    const handler = () => makeResponse(200, makeMcpEnvelope({
      content: "Not found",
      isError: true,
    }));
    const exit = await runFetchPage(handler, "/whoami");
    expect(Exit.isFailure(exit)).toBe(true);
  });
});

describe("McpClient.executeAction", () => {
  it("forwards context/path/action/params and returns markdown body with success=true", async () => {
    const handler = (opts: RailsRequestOptions) => {
      const payload = JSON.parse(opts.body ?? "{}");
      expect(payload.params.name).toBe("execute_action");
      expect(payload.params.arguments).toEqual({
        context: TEST_CONTEXT,
        path: "/c/foo/note",
        action: "create_note",
        params: { text: "hello" },
      });
      return makeResponse(200, makeMcpEnvelope({
        content: "## Action Success",
        toolCallLogId: "log-xyz",
      }));
    };
    const exit = await runExecuteAction(handler, "/c/foo/note", "create_note", { text: "hello" });
    expect(Exit.isSuccess(exit)).toBe(true);
    if (Exit.isSuccess(exit)) {
      expect(exit.value.success).toBe(true);
      expect(exit.value.content).toBe("## Action Success");
      expect(exit.value.mcpToolCallLogId).toBe("log-xyz");
    }
  });

  it("returns success=false when result envelope has isError: true (tool-level failure)", async () => {
    const handler = () => makeResponse(200, makeMcpEnvelope({
      content: "Validation failed: text can't be blank",
      isError: true,
    }));
    const exit = await runExecuteAction(handler, "/c/foo/note", "create_note", {});
    expect(Exit.isSuccess(exit)).toBe(true);
    if (Exit.isSuccess(exit)) {
      expect(exit.value.success).toBe(false);
      expect(exit.value.content).toMatch(/Validation failed/);
    }
  });

  it("omits params from arguments when undefined", async () => {
    let captured: Record<string, unknown> | undefined;
    const handler = (opts: RailsRequestOptions) => {
      captured = JSON.parse(opts.body ?? "{}").params.arguments;
      return makeResponse(200, makeMcpEnvelope({ content: "ok" }));
    };
    await runExecuteAction(handler, "/x", "noop");
    expect(captured).toEqual({ context: TEST_CONTEXT, path: "/x", action: "noop", params: {} });
  });

  it("surfaces 429 after exhausted retry as HarmonicApiError", async () => {
    // Both initial and retry return 429 → withRetryAfter surfaces the 429
    // and the catch path wraps it as HarmonicApiError.
    const handler = () => ({
      statusCode: 429,
      headers: { "retry-after": "0" } as Record<string, string>,
      text: async () => "rate limited",
    });
    const exit = await runExecuteAction(handler, "/x", "noop");
    expect(Exit.isFailure(exit)).toBe(true);
  });
});

