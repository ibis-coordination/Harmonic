import { describe, it, expect } from "vitest";
import { buildSystemPrompt, buildChatSystemPrompt, AGENT_TOOLS } from "../../src/core/AgentContext.js";

describe("buildSystemPrompt", () => {
  it("includes preamble", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("You are an AI agent navigating Harmonic");
    expect(prompt).toContain("group coordination application");
  });

  it("includes boundaries with hierarchy", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("## Boundaries");
    expect(prompt).toContain("Ethical foundations");
    expect(prompt).toContain("Platform rules");
    expect(prompt).toContain("Your identity prompt");
    expect(prompt).toContain("User content");
    expect(prompt).toContain("Outer levels take precedence");
  });

  it("includes Harmonic concepts matching Ruby implementation", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("## Harmonic Concepts");
    expect(prompt).toContain("Collectives");
    expect(prompt).toContain("Notes");
    expect(prompt).toContain("Decisions");
    expect(prompt).toContain("acceptance voting");
    expect(prompt).toContain("Commitments");
    expect(prompt).toContain("critical mass");
    expect(prompt).toContain("Cycles");
    expect(prompt).toContain("Heartbeats");
  });

  it("includes useful paths", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("/whoami");
    expect(prompt).toContain("/collectives/{handle}");
  });

  it("includes tool instructions", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("navigate");
    expect(prompt).toContain("execute_action");
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

  it("includes private workspace concept", () => {
    const prompt = buildSystemPrompt("", undefined);
    expect(prompt).toContain("Private Workspace");
    expect(prompt).toContain("persistent memory");
    expect(prompt).toContain("/workspace");
  });
});

describe("buildChatSystemPrompt", () => {
  it("includes memory guidance in chat behavior", () => {
    const prompt = buildChatSystemPrompt("", undefined, undefined);
    expect(prompt).toContain("searching your private workspace");
    expect(prompt).toContain("saving it as a note in your workspace");
  });

  it("includes private workspace concept", () => {
    const prompt = buildChatSystemPrompt("", undefined, undefined);
    expect(prompt).toContain("Private Workspace");
    expect(prompt).toContain("/workspace");
  });
});

describe("AGENT_TOOLS", () => {
  it("has navigate and execute_action tools", () => {
    expect(AGENT_TOOLS.length).toBe(2);
    expect(AGENT_TOOLS.map((t) => t.function.name)).toEqual(["navigate", "execute_action"]);
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
});
