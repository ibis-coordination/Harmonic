import { describe, it, expect } from "vitest";
import { Effect, Layer, Exit } from "effect";
import { HarmonicClient, HarmonicClientLive, parseAvailableActions, type NavigateResult } from "../../src/services/HarmonicClient.js";
import { RailsHttp } from "../../src/services/RailsHttp.js";
import type { RailsRequestOptions, RailsResponse } from "../../src/services/RailsHttp.js";
import { Config } from "../../src/config/Config.js";
import { createRetryBudget } from "../../src/services/Retry.js";
import type { HarmonicApiError } from "../../src/errors/Errors.js";

// --- Test helpers for navigate ---

function makeResponse(statusCode: number, body: string, headers: Record<string, string> = {}): RailsResponse {
  return {
    statusCode,
    headers,
    text: async () => body,
  };
}

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

function buildTestLayer(requestHandler: (opts: RailsRequestOptions) => RailsResponse) {
  const RailsHttpTest = Layer.succeed(RailsHttp, {
    request: async (opts: RailsRequestOptions) => requestHandler(opts),
  });
  const ConfigTest = Layer.succeed(Config, TEST_CONFIG);
  return HarmonicClientLive.pipe(Layer.provide(Layer.merge(RailsHttpTest, ConfigTest)));
}

function runNavigate(
  requestHandler: (opts: RailsRequestOptions) => RailsResponse,
  path: string,
): Promise<Exit.Exit<NavigateResult, HarmonicApiError>> {
  const layer = buildTestLayer(requestHandler);
  const program = Effect.gen(function* () {
    const client = yield* HarmonicClient;
    return yield* client.navigate(path, "test-token", "app", createRetryBudget());
  });
  return Effect.runPromiseExit(program.pipe(Effect.provide(layer)));
}

function runExecuteAction(
  requestHandler: (opts: RailsRequestOptions) => RailsResponse,
  path: string,
  action: string,
  params: Record<string, unknown> = {},
): Promise<Exit.Exit<{ content: string; success: boolean }, HarmonicApiError>> {
  const layer = buildTestLayer(requestHandler);
  const program = Effect.gen(function* () {
    const client = yield* HarmonicClient;
    return yield* client.executeAction(path, action, params, "test-token", "app", createRetryBudget());
  });
  return Effect.runPromiseExit(program.pipe(Effect.provide(layer)));
}

describe("executeAction URL construction", () => {
  it("strips ?query string from path before appending /actions/<name>", async () => {
    let observedPath = "";
    const handler = (opts: RailsRequestOptions) => {
      observedPath = opts.path;
      return makeResponse(200, "Comment added");
    };

    const exit = await runExecuteAction(handler, "/d/abc?comment_id=xyz", "add_comment", { text: "hi" });

    expect(Exit.isSuccess(exit)).toBe(true);
    expect(observedPath).toBe("/d/abc/actions/add_comment");
  });

  it("works correctly when path has no query string", async () => {
    let observedPath = "";
    const handler = (opts: RailsRequestOptions) => {
      observedPath = opts.path;
      return makeResponse(200, "OK");
    };

    await runExecuteAction(handler, "/d/abc", "vote", { option_title: "yes" });

    expect(observedPath).toBe("/d/abc/actions/vote");
  });
});

describe("navigate redirect following", () => {
  it("follows a single redirect", async () => {
    const requests: string[] = [];
    const result = await runNavigate((opts) => {
      requests.push(opts.path);
      if (opts.path === "/workspace") {
        return makeResponse(302, "", { location: "/workspace/abc123" });
      }
      return makeResponse(200, "# Workspace\n\nContent here.");
    }, "/workspace");

    expect(Exit.isSuccess(result)).toBe(true);
    if (Exit.isSuccess(result)) {
      expect(result.value.content).toContain("# Workspace");
      expect(result.value.resolvedPath).toBe("/workspace/abc123");
    }
    expect(requests).toEqual(["/workspace", "/workspace/abc123"]);
  });

  it("follows multiple redirects", async () => {
    const requests: string[] = [];
    const result = await runNavigate((opts) => {
      requests.push(opts.path);
      if (opts.path === "/a") return makeResponse(301, "", { location: "/b" });
      if (opts.path === "/b") return makeResponse(302, "", { location: "/c" });
      return makeResponse(200, "# Final page");
    }, "/a");

    expect(Exit.isSuccess(result)).toBe(true);
    if (Exit.isSuccess(result)) {
      expect(result.value.content).toContain("# Final page");
      expect(result.value.resolvedPath).toBe("/c");
    }
    expect(requests).toEqual(["/a", "/b", "/c"]);
  });

  it("handles absolute URL in Location header", async () => {
    const requests: string[] = [];
    const result = await runNavigate((opts) => {
      requests.push(opts.path);
      if (opts.path === "/workspace") {
        return makeResponse(302, "", { location: "https://app.harmonic.local/workspace/abc123" });
      }
      return makeResponse(200, "# Workspace");
    }, "/workspace");

    expect(Exit.isSuccess(result)).toBe(true);
    expect(requests).toEqual(["/workspace", "/workspace/abc123"]);
  });

  it("fails after too many redirects", async () => {
    const result = await runNavigate((opts) => {
      const n = parseInt(opts.path.slice(1)) || 0;
      return makeResponse(302, "", { location: `/${n + 1}` });
    }, "/0");

    expect(Exit.isFailure(result)).toBe(true);
    if (Exit.isFailure(result)) {
      const error = result.cause;
      expect(String(error)).toContain("too many redirects");
    }
  });

  it("returns success directly when no redirect", async () => {
    const result = await runNavigate(() => {
      return makeResponse(200, "---\nactions:\n  - name: create_note\n---\n# Page");
    }, "/collectives/team");

    expect(Exit.isSuccess(result)).toBe(true);
    if (Exit.isSuccess(result)) {
      expect(result.value.content).toContain("# Page");
      expect(result.value.availableActions).toEqual(["create_note"]);
      expect(result.value.resolvedPath).toBe("/collectives/team");
    }
  });

  it("fails on non-redirect error status", async () => {
    const result = await runNavigate(() => {
      return makeResponse(404, "Not Found");
    }, "/nonexistent");

    expect(Exit.isFailure(result)).toBe(true);
  });

  it("fails on 3xx without Location header", async () => {
    const result = await runNavigate(() => {
      return makeResponse(302, "Redirecting...");
    }, "/bad-redirect");

    expect(Exit.isFailure(result)).toBe(true);
    if (Exit.isFailure(result)) {
      expect(String(result.cause)).toContain("302");
    }
  });

  it("resolvedPath equals original path when no redirect", async () => {
    const result = await runNavigate(() => {
      return makeResponse(200, "# Direct page");
    }, "/direct");

    expect(Exit.isSuccess(result)).toBe(true);
    if (Exit.isSuccess(result)) {
      expect(result.value.resolvedPath).toBe("/direct");
    }
  });
});

describe("parseAvailableActions", () => {
  it("parses action names from YAML frontmatter", () => {
    const content = `---
app: Harmonic
host: test.harmonic.local
path: /collectives/team
actions:
  - name: create_note
    description: Create a new note
    path: /collectives/team/actions/create_note
    params:
      - name: body
        type: string
        required: true
  - name: vote
    description: Cast a vote
    path: /collectives/team/actions/vote
---
nav: | [Home](/) |

# Team Collective
`;
    const actions = parseAvailableActions(content);
    expect(actions).toEqual(["create_note", "vote"]);
  });

  it("returns empty array when no frontmatter", () => {
    const content = "# Just a page\n\nSome content here.";
    expect(parseAvailableActions(content)).toEqual([]);
  });

  it("returns empty array for empty content", () => {
    expect(parseAvailableActions("")).toEqual([]);
  });

  it("returns empty array when frontmatter has no actions", () => {
    const content = `---
app: Harmonic
host: test.harmonic.local
path: /whoami
---
# About You
`;
    expect(parseAvailableActions(content)).toEqual([]);
  });

  it("handles frontmatter with single action", () => {
    const content = `---
actions:
  - name: send_heartbeat
    description: Send heartbeat
---
# Page
`;
    const actions = parseAvailableActions(content);
    expect(actions).toEqual(["send_heartbeat"]);
  });

  it("ignores actions without name field", () => {
    const content = `---
actions:
  - name: valid_action
    description: Valid
  - description: No name field
  - name: another_valid
    description: Also valid
---
# Page
`;
    const actions = parseAvailableActions(content);
    expect(actions).toEqual(["valid_action", "another_valid"]);
  });

  it("handles malformed YAML gracefully", () => {
    const content = `---
actions: [not valid yaml
---
# Page
`;
    // Should not throw, return empty
    expect(parseAvailableActions(content)).toEqual([]);
  });

  it("does not confuse horizontal rules for frontmatter", () => {
    const content = `# Page Title

Some content

---

More content after rule
`;
    expect(parseAvailableActions(content)).toEqual([]);
  });
});

describe("navigate Retry-After backoff", () => {
  it("retries once on 429 with Retry-After and surfaces the eventual 200", async () => {
    const calls: number[] = [];
    let i = 0;
    const RailsHttpTest = Layer.succeed(RailsHttp, {
      request: async (opts: RailsRequestOptions) => {
        calls.push(opts.method === "GET" ? 1 : 0);
        if (i++ === 0) {
          return { statusCode: 429, headers: { "retry-after": "0" }, text: async () => "" };
        }
        return makeResponse(200, "# Hello");
      },
    });
    const ConfigTest = Layer.succeed(Config, TEST_CONFIG);
    const layer = HarmonicClientLive.pipe(Layer.provide(Layer.merge(RailsHttpTest, ConfigTest)));

    const program = Effect.gen(function* () {
      const client = yield* HarmonicClient;
      return yield* client.navigate("/whoami", "tok", "app", createRetryBudget());
    });
    const exit = await Effect.runPromiseExit(program.pipe(Effect.provide(layer)));

    expect(Exit.isSuccess(exit)).toBe(true);
    if (Exit.isSuccess(exit)) {
      expect(exit.value.content).toContain("# Hello");
    }
    expect(calls.length).toBe(2);
  });

  it("surfaces a HarmonicApiError when 429 retry also 429s", async () => {
    const RailsHttpTest = Layer.succeed(RailsHttp, {
      request: async (_opts: RailsRequestOptions) => {
        return { statusCode: 429, headers: { "retry-after": "0" }, text: async () => "rate limited" };
      },
    });
    const ConfigTest = Layer.succeed(Config, TEST_CONFIG);
    const layer = HarmonicClientLive.pipe(Layer.provide(Layer.merge(RailsHttpTest, ConfigTest)));

    const program = Effect.gen(function* () {
      const client = yield* HarmonicClient;
      return yield* client.navigate("/whoami", "tok", "app", createRetryBudget());
    });
    const exit = await Effect.runPromiseExit(program.pipe(Effect.provide(layer)));

    expect(Exit.isFailure(exit)).toBe(true);
  });
});
