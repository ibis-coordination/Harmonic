import { describe, it, expect } from "vitest";
import { buildSystemPrompt, buildChatSystemPrompt, AGENT_TOOLS } from "../../src/core/AgentContext.js";

describe("buildSystemPrompt", () => {
  it("includes what Harmonic is", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("group coordination application");
    expect(prompt).toContain("navigating pages");
  });

  it("includes domain quick reference table", () => {
    const prompt = buildSystemPrompt("", undefined);
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
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("/help/collectives");
    expect(prompt).toContain("/help/notes");
    expect(prompt).toContain("/help/decisions");
    expect(prompt).toContain("/help/commitments");
    expect(prompt).toContain("/help/cycles");
    expect(prompt).toContain("/help/agents");
  });

  it("includes navigation section with key paths", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("## Navigation");
    expect(prompt).toContain("/whoami");
    expect(prompt).toContain("/workspace");
    expect(prompt).toContain("/collectives/{handle}");
    expect(prompt).toContain("/notifications");
    expect(prompt).toContain("/help");
    expect(prompt).toContain("search?q=");
  });

  it("includes discovery strategy", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("Start at `/whoami`");
    expect(prompt).toContain("navigate to the relevant `/help` page");
  });

  it("includes tool instructions", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("navigate");
    expect(prompt).toContain("execute_action");
    expect(prompt).toContain("search");
    expect(prompt).toContain("get_help");
    expect(prompt).toContain("four tools");
  });

  it("includes boundaries with hierarchy", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("## Boundaries");
    expect(prompt).toContain("Ethical foundations");
    expect(prompt).toContain("Platform rules");
    expect(prompt).toContain("Outer levels take precedence");
  });

  it("includes identity when provided", () => {
    const prompt = buildSystemPrompt("I am a friendly bot", undefined);
    expect(prompt).toContain("Your Identity");
    expect(prompt).toContain("friendly bot");
  });

  it("excludes identity section when empty", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).not.toContain("Your Identity");
  });

  it("includes scratchpad when provided", () => {
    const prompt = buildSystemPrompt("", "Previous notes here");
    expect(prompt).toContain("Scratchpad");
    expect(prompt).toContain("Previous notes here");
  });

  it("excludes scratchpad section when empty", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).not.toContain("Scratchpad");
  });
});

describe("buildChatSystemPrompt", () => {
  it("includes working patterns for chat", () => {
    const prompt = buildChatSystemPrompt("", undefined, undefined);
    expect(prompt).toContain("Working Patterns");
    expect(prompt).toContain("respond_to_human");
    expect(prompt).toContain("searching your private workspace");
    expect(prompt).toContain("saving it as a note in your workspace");
  });

  it("includes domain quick reference", () => {
    const prompt = buildChatSystemPrompt("", undefined, undefined);
    expect(prompt).toContain("Harmonic Quick Reference");
    expect(prompt).toContain("Private Workspace");
    expect(prompt).toContain("/workspace");
  });

  it("includes chat tools with respond_to_human", () => {
    const prompt = buildChatSystemPrompt("", undefined, undefined);
    expect(prompt).toContain("respond_to_human");
    expect(prompt).toContain("five tools");
  });

  it("includes time context when provided", () => {
    const prompt = buildChatSystemPrompt("", undefined, "5 minutes");
    expect(prompt).toContain("Time Context");
    expect(prompt).toContain("5 minutes ago");
  });

  it("excludes time context when not provided", () => {
    const prompt = buildChatSystemPrompt("", undefined, undefined);
    expect(prompt).not.toContain("Time Context");
  });
});

describe("AGENT_TOOLS", () => {
  it("has all four tools", () => {
    expect(AGENT_TOOLS.length).toBe(4);
    expect(AGENT_TOOLS.map((t) => t.function.name)).toEqual([
      "navigate", "execute_action", "search", "get_help",
    ]);
  });

  it("navigate has path parameter", () => {
    const nav = AGENT_TOOLS[0];
    const props = nav?.function.parameters as Record<string, unknown>;
    const properties = props["properties"] as Record<string, unknown>;
    expect(properties["path"]).toBeDefined();
  });

  it("execute_action has action and params parameters", () => {
    const exec = AGENT_TOOLS[1];
    const props = exec?.function.parameters as Record<string, unknown>;
    const properties = props["properties"] as Record<string, unknown>;
    expect(properties["action"]).toBeDefined();
    expect(properties["params"]).toBeDefined();
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
