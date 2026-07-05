import { describe, it, expect } from "vitest";
import { parseStreamEntry } from "../../src/services/TaskQueue.js";

function fields(overrides: Record<string, string> = {}): string[] {
  const base: Record<string, string> = {
    task_run_id: "run-1",
    encrypted_token: "enc-token",
    task: "Do the thing",
    max_steps: "10",
    model: "anthropic/claude-sonnet-4-6",
    agent_id: "agent-1",
    tenant_subdomain: "test",
    stripe_customer_stripe_id: "cus_abc",
    mode: "task",
    chat_session_id: "",
    ...overrides,
  };
  return Object.entries(base).flat();
}

describe("parseStreamEntry gateway mode", () => {
  it("parses llm_gateway_mode stripe_gateway", () => {
    const task = parseStreamEntry(fields({ llm_gateway_mode: "stripe_gateway" }));
    expect(task?.llmGatewayMode).toBe("stripe_gateway");
  });

  it("parses llm_gateway_mode litellm", () => {
    const task = parseStreamEntry(fields({ llm_gateway_mode: "litellm" }));
    expect(task?.llmGatewayMode).toBe("litellm");
  });

  it("leaves llmGatewayMode undefined when the field is absent (pre-upgrade payloads)", () => {
    const task = parseStreamEntry(fields());
    expect(task).not.toBeNull();
    expect(task?.llmGatewayMode).toBeUndefined();
  });

  it("leaves llmGatewayMode undefined for unrecognized values", () => {
    const task = parseStreamEntry(fields({ llm_gateway_mode: "bogus" }));
    expect(task?.llmGatewayMode).toBeUndefined();
  });
});
