import { describe, it, expect, vi } from "vitest";
import { createLogger } from "../../src/services/Logger.js";

describe("Logger", () => {
  it("outputs JSON with required fields", () => {
    const spy = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    const log = createLogger();

    log.info({ event: "task_received", taskRunId: "abc" });

    expect(spy).toHaveBeenCalledOnce();
    const output = spy.mock.calls[0][0] as string;
    const parsed = JSON.parse(output);
    expect(parsed.level).toBe("info");
    expect(parsed.event).toBe("task_received");
    expect(parsed.taskRunId).toBe("abc");
    expect(parsed.timestamp).toBeDefined();

    spy.mockRestore();
  });

  it("outputs one line per call (no embedded newlines except trailing)", () => {
    const spy = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    const log = createLogger();

    log.warn({ event: "agent_busy", agentId: "a1" });

    const output = spy.mock.calls[0][0] as string;
    expect(output.endsWith("\n")).toBe(true);
    expect(output.trim().includes("\n")).toBe(false);

    spy.mockRestore();
  });

  it("supports error level with message field", () => {
    const spy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const log = createLogger();

    log.error({ event: "queue_error", message: "Redis down" });

    const output = spy.mock.calls[0][0] as string;
    const parsed = JSON.parse(output);
    expect(parsed.level).toBe("error");
    expect(parsed.message).toBe("Redis down");

    spy.mockRestore();
  });

  it("includes extra fields passed in", () => {
    const spy = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    const log = createLogger();

    log.info({ event: "started", maxConcurrent: 100, streamMaxLen: 10000 });

    const parsed = JSON.parse(spy.mock.calls[0][0] as string);
    expect(parsed.maxConcurrent).toBe(100);
    expect(parsed.streamMaxLen).toBe(10000);

    spy.mockRestore();
  });
});
