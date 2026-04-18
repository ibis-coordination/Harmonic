import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { fork } from "node:child_process";
import { resolve } from "node:path";
import { createCipheriv, hkdfSync, randomBytes } from "node:crypto";

const TEST_SECRET = "test-secret-for-shutdown-test";
const HKDF_INFO = "agent-runner-token-encryption";
const REDIS_URL = process.env.REDIS_URL ?? "redis://localhost:6379";

function encryptToken(plaintext: string): string {
  const key = Buffer.from(hkdfSync("sha256", TEST_SECRET, "", HKDF_INFO, 32));
  const iv = Buffer.alloc(12, 1);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.alloc(0));
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return Buffer.concat([iv, authTag, encrypted]).toString("base64");
}

/** Spawn the agent-runner with a unique stream name to avoid test interference. */
function spawnRunner(streamName: string) {
  const entryPoint = resolve(import.meta.dirname, "../../dist/index.js");
  const logs: string[] = [];

  const child = fork(entryPoint, [], {
    env: {
      ...process.env,
      AGENT_RUNNER_SECRET: TEST_SECRET,
      REDIS_URL,
      HARMONIC_INTERNAL_URL: "http://localhost:3000",
      HARMONIC_HOSTNAME: "test.local",
      AGENT_TASKS_STREAM: streamName,
    },
    stdio: ["pipe", "pipe", "pipe", "ipc"],
  });

  const collectLogs = (data: Buffer) => {
    for (const line of data.toString().split("\n").filter(Boolean)) {
      logs.push(line);
    }
  };
  child.stdout?.on("data", collectLogs);
  child.stderr?.on("data", collectLogs);

  const waitForEvent = (eventName: string, timeoutMs = 10_000) =>
    new Promise<boolean>((resolve) => {
      // Check if already in logs
      if (logs.some((l) => l.includes(`"event":"${eventName}"`))) {
        resolve(true);
        return;
      }

      const timeout = setTimeout(() => resolve(false), timeoutMs);

      const check = () => {
        if (logs.some((l) => l.includes(`"event":"${eventName}"`))) {
          clearTimeout(timeout);
          resolve(true);
        }
      };
      child.stdout?.on("data", check);
      child.stderr?.on("data", check);
      child.on("exit", () => { clearTimeout(timeout); resolve(false); });
    });

  const waitForExit = (timeoutMs = 15_000) =>
    new Promise<number | null>((resolve) => {
      const timeout = setTimeout(() => { child.kill("SIGKILL"); resolve(null); }, timeoutMs);
      child.on("exit", (code) => { clearTimeout(timeout); resolve(code); });
    });

  const parseEvents = () =>
    logs
      .map((line) => { try { return JSON.parse(line); } catch { return null; } })
      .filter((e): e is Record<string, unknown> => e !== null && typeof e === "object");

  return { child, logs, waitForEvent, waitForExit, parseEvents };
}

/** Check if Redis is available by attempting a connection. */
async function redisAvailable(): Promise<boolean> {
  try {
    const { Redis } = await import("ioredis");
    const r = new Redis(REDIS_URL, { lazyConnect: true, connectTimeout: 2000 });
    await r.connect();
    await r.ping();
    r.disconnect();
    return true;
  } catch {
    return false;
  }
}

/**
 * Integration tests for graceful shutdown.
 * Spawns the agent-runner as a child process, sends SIGTERM, and verifies
 * it exits cleanly with the expected log events.
 *
 * Each test uses a unique Redis stream name to avoid interference from
 * other tests or previous runs.
 *
 * Requires Redis on localhost:6379 (available in CI; locally via docker-compose port mapping).
 */
describe("graceful shutdown", () => {
  let hasRedis = false;
  const streamsToCleanup: string[] = [];

  beforeAll(async () => {
    hasRedis = await redisAvailable();
  });

  afterAll(async () => {
    if (!hasRedis || streamsToCleanup.length === 0) return;
    const { Redis } = await import("ioredis");
    const redis = new Redis(REDIS_URL);
    for (const stream of streamsToCleanup) {
      await redis.del(stream).catch(() => {});
    }
    redis.disconnect();
  });

  it("exits cleanly on SIGTERM with no active tasks", async () => {
    if (!hasRedis) {
      console.log("Skipping: Redis not available");
      return;
    }

    const stream = `agent_tasks_test_${randomBytes(4).toString("hex")}`;
    streamsToCleanup.push(stream);

    const runner = spawnRunner(stream);
    const started = await runner.waitForEvent("started");
    expect(started).toBe(true);

    runner.child.kill("SIGTERM");
    const exitCode = await runner.waitForExit();

    const events = runner.parseEvents().map((e) => e.event);
    expect(events).toContain("started");
    expect(events).toContain("shutdown_requested");
    expect(events).toContain("shutdown_complete");
    expect(exitCode).toBe(0);
  }, 30_000);

  it("drains active tasks before exiting on SIGTERM", async () => {
    if (!hasRedis) {
      console.log("Skipping: Redis not available");
      return;
    }

    const stream = `agent_tasks_test_${randomBytes(4).toString("hex")}`;
    streamsToCleanup.push(stream);

    const { Redis } = await import("ioredis");
    const redis = new Redis(REDIS_URL);

    const runner = spawnRunner(stream);
    const started = await runner.waitForEvent("started");
    expect(started).toBe(true);

    // Push 3 tasks. Each takes ~5 seconds (preflight fails → reporter.fail retries
    // with backoff: 250ms + 1s + 4s). With 3 concurrent tasks, at least one will
    // still be in-flight when SIGTERM fires, exercising the drain wait.
    for (let i = 1; i <= 3; i++) {
      await redis.xadd(
        stream, "MAXLEN", "~", "10000", "*",
        "task_run_id", `test-drain-task-${i}`,
        "encrypted_token", encryptToken(`fake-api-token-for-drain-test-${i}-pad12345`),
        "task", "Test drain behavior",
        "max_steps", "5",
        "model", "",
        "agent_id", `test-agent-${i}`,
        "tenant_subdomain", "test",
        "stripe_customer_stripe_id", "",
      );
    }

    // Send SIGTERM as soon as we see the first task_received — tasks are in-flight
    // with preflight retries taking several seconds.
    await new Promise<void>((resolve) => {
      const timeout = setTimeout(() => resolve(), 10_000);
      const check = () => {
        if (runner.logs.some((l) => l.includes('"event":"task_received"'))) {
          clearTimeout(timeout);
          runner.child.kill("SIGTERM");
          resolve();
        }
      };
      runner.child.stdout?.on("data", check);
      runner.child.stderr?.on("data", check);
    });

    expect(runner.logs.some((l) => l.includes('"event":"task_received"'))).toBe(true);

    // The runner should drain — wait for it to exit
    const exitCode = await runner.waitForExit(30_000);

    const events = runner.parseEvents();
    const eventNames = events.map((e) => e.event);

    expect(eventNames).toContain("started");
    expect(eventNames).toContain("task_received");
    expect(eventNames).toContain("shutdown_requested");

    // The shutdown_requested should show activeTasks > 0
    const shutdownEvent = events.find((e) => e.event === "shutdown_requested");
    expect(shutdownEvent?.activeTasks).toBeGreaterThan(0);

    // Should have entered draining mode and waited for tasks to finish
    expect(eventNames).toContain("draining");

    // Should eventually complete shutdown after task finishes/fails
    expect(eventNames).toContain("shutdown_complete");

    // shutdown_complete should show activeTasks back to 0
    const completeEvent = events.find((e) => e.event === "shutdown_complete");
    expect(completeEvent?.activeTasks).toBe(0);

    expect(exitCode).toBe(0);

    redis.disconnect();
  }, 60_000);
});
