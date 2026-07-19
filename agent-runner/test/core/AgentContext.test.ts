import { describe, it, expect } from "vitest";
import { buildSystemPrompt, buildChatSystemPrompt, AGENT_TOOLS } from "../../src/core/AgentContext.js";

describe("buildSystemPrompt", () => {
  it("includes what Harmonic is", () => {
    const prompt = buildSystemPrompt("");
    expect(prompt).toContain("group coordination application");
    expect(prompt).toContain("reading pages");
  });

  it("includes domain quick reference table", () => {
    const prompt = buildSystemPrompt("");
    expect(prompt).toContain("Harmonic Quick Reference");
    expect(prompt).toContain("Collective");
    expect(prompt).toContain("Note");
    expect(prompt).toContain("Decision");
    expect(prompt).toContain("acceptance voting");
    expect(prompt).toContain("Commitment");
    expect(prompt).toContain("critical mass");
    expect(prompt).toContain("Cycle");
    expect(prompt).toContain("Heartbeat");
    expect(prompt).toContain("Private Workspace");
  });

  it("points to /help pages for details", () => {
    const prompt = buildSystemPrompt("");
    expect(prompt).toContain("/help/collectives");
    expect(prompt).toContain("/help/notes");
    expect(prompt).toContain("/help/decisions");
    expect(prompt).toContain("/help/commitments");
    expect(prompt).toContain("/help/cycles");
    expect(prompt).toContain("/help/agents");
  });

  it("includes navigation section with key paths", () => {
    const prompt = buildSystemPrompt("");
    expect(prompt).toContain("## Navigation");
    expect(prompt).toContain("/whoami");
    expect(prompt).toContain("/workspace");
    expect(prompt).toContain("/collectives/{handle}");
    expect(prompt).toContain("/notifications");
    expect(prompt).toContain("/help");
    expect(prompt).toContain("search?q=");
  });

  it("includes discovery strategy", () => {
    const prompt = buildSystemPrompt("");
    expect(prompt).toContain("Start at `/whoami`");
    expect(prompt).toContain("fetch_page");
  });

  it("includes tool instructions", () => {
    const prompt = buildSystemPrompt("");
    expect(prompt).toContain("fetch_page");
    expect(prompt).toContain("execute_action");
    expect(prompt).toContain("search");
    expect(prompt).toContain("get_help");
    expect(prompt).toContain("four tools");
  });

  it("includes boundaries with hierarchy", () => {
    const prompt = buildSystemPrompt("");
    expect(prompt).toContain("## Boundaries");
    expect(prompt).toContain("Ethical foundations");
    expect(prompt).toContain("Platform rules");
    expect(prompt).toContain("Outer levels take precedence");
  });

  it("includes identity when provided", () => {
    const prompt = buildSystemPrompt("I am a friendly bot");
    expect(prompt).toContain("Your Identity");
    expect(prompt).toContain("friendly bot");
  });

  it("excludes identity section when empty", () => {
    const prompt = buildSystemPrompt("");
    expect(prompt).not.toContain("Your Identity");
  });

  it("does not add its own scratchpad section — the whoami identity content already carries one", () => {
    const identity = "# About You\n\n## Your Scratchpad\n\nMy notes";
    const prompt = buildSystemPrompt(identity);
    expect(prompt.split("My notes").length - 1).toBe(1);
  });
});

describe("buildChatSystemPrompt", () => {
  it("includes working patterns for chat", () => {
    const prompt = buildChatSystemPrompt("", undefined);
    expect(prompt).toContain("Working Patterns");
    expect(prompt).toContain("respond_to_human");
    expect(prompt).toContain("searching your private workspace");
    expect(prompt).toContain("saving it as a note in your workspace");
  });

  it("instructs the agent to surface resource paths in its replies so chat turns can refer back", () => {
    // Only the assistant's text crosses turn boundaries — tool calls and
    // their results don't. The agent has to put identifying context in its
    // reply for follow-up turns to make sense.
    const prompt = buildChatSystemPrompt("", undefined);
    expect(prompt).toMatch(/path|link/i);
    expect(prompt).toMatch(/tool calls.*(don't|do not)|text persists/i);
  });

  it("includes domain quick reference", () => {
    const prompt = buildChatSystemPrompt("", undefined);
    expect(prompt).toContain("Harmonic Quick Reference");
    expect(prompt).toContain("Private Workspace");
    expect(prompt).toContain("/workspace");
  });

  it("includes chat tools with respond_to_human", () => {
    const prompt = buildChatSystemPrompt("", undefined);
    expect(prompt).toContain("respond_to_human");
    expect(prompt).toContain("five tools");
  });

  it("includes time context when provided", () => {
    const prompt = buildChatSystemPrompt("", "5 minutes");
    expect(prompt).toContain("Time Context");
    expect(prompt).toContain("5 minutes ago");
  });

  it("excludes time context when not provided", () => {
    const prompt = buildChatSystemPrompt("", undefined);
    expect(prompt).not.toContain("Time Context");
  });
});

describe("AGENT_TOOLS", () => {
  it("has all four tools", () => {
    expect(AGENT_TOOLS.length).toBe(4);
    expect(AGENT_TOOLS.map((t) => t.function.name)).toEqual([
      "fetch_page", "execute_action", "search", "get_help",
    ]);
  });

  it("fetch_page has path parameter", () => {
    const fetchTool = AGENT_TOOLS[0];
    const props = fetchTool?.function.parameters as Record<string, unknown>;
    const properties = props["properties"] as Record<string, unknown>;
    expect(properties["path"]).toBeDefined();
  });

  it("execute_action has context, path, action, and params parameters; context, path, action required", () => {
    const exec = AGENT_TOOLS[1];
    const props = exec?.function.parameters as Record<string, unknown>;
    const properties = props["properties"] as Record<string, unknown>;
    expect(properties["context"]).toBeDefined();
    expect(properties["path"]).toBeDefined();
    expect(properties["action"]).toBeDefined();
    expect(properties["params"]).toBeDefined();
    expect(props["required"]).toEqual(["context", "path", "action"]);
  });

  it("execute_action's context requires identity, visibility, and intention", () => {
    const exec = AGENT_TOOLS[1];
    const props = exec?.function.parameters as Record<string, unknown>;
    const properties = props["properties"] as Record<string, unknown>;
    const context = properties["context"] as Record<string, unknown>;
    expect(context["required"]).toEqual(["identity", "visibility", "intention"]);
    const contextProps = context["properties"] as Record<string, unknown>;
    expect(contextProps["identity"]).toBeDefined();
    expect(contextProps["visibility"]).toBeDefined();
    expect(contextProps["intention"]).toBeDefined();
  });

  it("search has query parameter", () => {
    const search = AGENT_TOOLS[2];
    const props = search?.function.parameters as Record<string, unknown>;
    const properties = props["properties"] as Record<string, unknown>;
    expect(properties["query"]).toBeDefined();
  });

  it("get_help has topic parameter", () => {
    const help = AGENT_TOOLS[3];
    const props = help?.function.parameters as Record<string, unknown>;
    const properties = props["properties"] as Record<string, unknown>;
    expect(properties["topic"]).toBeDefined();
  });
});
