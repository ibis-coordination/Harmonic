import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { fork } from "node:child_process";
import { resolve } from "node:path";
import { createCipheriv, hkdfSync, randomBytes } from "node:crypto";
import { createServer, type Server } from "node:http";

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

/**
 * Start a mock Rails server that delays the first request, then responds
 * quickly to subsequent ones. The initial delay keeps the task in-flight
 * long enough for SIGTERM to land; quick follow-ups let the task finish
 * within the drain window.
 */
function startSlowMockServer(firstRequestDelayMs: number): Promise<{ server: Server; port: number }> {
  return new Promise((resolve) => {
    let requestCount = 0;
    const server = createServer((_req, res) => {
      requestCount++;
      const delay = requestCount === 1 ? firstRequestDelayMs : 0;
      setTimeout(() => {
        // Return 500 for all requests — task will fail quickly after the
        // initial slow response, rather than proceeding through claim/LLM/etc.
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "mock server" }));
      }, delay);
    });
    server.listen(0, () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr !== null ? addr.port : 0;
      resolve({ server, port });
    });
  });
}

/** Spawn the agent-runner with a unique stream name to avoid test interference. */
function spawnRunner(streamName: string, internalUrl: string) {
  const entryPoint = resolve(import.meta.dirname, "../../dist/index.js");
  const logs: string[] = [];

  const child = fork(entryPoint, [], {
    env: {
      ...process.env,
      AGENT_RUNNER_SECRET: TEST_SECRET,
      REDIS_URL,
      HARMONIC_INTERNAL_URL: internalUrl,
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

    const runner = spawnRunner(stream, "http://localhost:3000");
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

    // Start a mock server that delays the first response by 8 seconds.
    // This must exceed the XREADGROUP BLOCK timeout (5 seconds) so the
    // task is still in-flight when the main loop unwinds after SIGTERM.
    // Subsequent requests return 500 immediately so the task fails fast
    // and the drain completes quickly.
    const mock = await startSlowMockServer(8_000);

    const stream = `agent_tasks_test_${randomBytes(4).toString("hex")}`;
    streamsToCleanup.push(stream);

    const { Redis } = await import("ioredis");
    const redis = new Redis(REDIS_URL);

    const runner = spawnRunner(stream, `http://localhost:${mock.port}`);
    const started = await runner.waitForEvent("started");
    expect(started).toBe(true);

    // Push a task. The runner will pick it up and call preflight on our
    // mock server, which delays 8 seconds — keeping the task in-flight.
    await redis.xadd(
      stream, "MAXLEN", "~", "10000", "*",
      "task_run_id", "test-drain-task-1",
      "encrypted_token", encryptToken("fake-api-token-for-drain-test-1-pad12345"),
      "task", "Test drain behavior",
      "max_steps", "5",
      "model", "",
      "agent_id", "test-agent-1",
      "tenant_subdomain", "test",
      "stripe_customer_stripe_id", "",
    );

    // Wait for the task to be picked up
    const received = await runner.waitForEvent("task_received", 10_000);
    expect(received).toBe(true);

    // Small delay to ensure the task fiber has started and is blocked on preflight
    await new Promise((r) => setTimeout(r, 200));

    // Send SIGTERM — the task is in-flight (blocked on slow preflight)
    runner.child.kill("SIGTERM");

    // The runner should drain — wait for it to exit
    const exitCode = await runner.waitForExit(30_000);

    const events = runner.parseEvents();
    const eventNames = events.map((e) => e.event);

    expect(eventNames).toContain("started");
    expect(eventNames).toContain("task_received");
    expect(eventNames).toContain("shutdown_requested");

    // shutdown_requested must show activeTasks > 0 (task is blocked on preflight)
    const shutdownEvent = events.find((e) => e.event === "shutdown_requested");
    expect(shutdownEvent?.activeTasks).toBeGreaterThan(0);

    // Must have entered draining mode and waited
    expect(eventNames).toContain("draining");

    // Should eventually complete shutdown after task finishes
    expect(eventNames).toContain("shutdown_complete");

    // shutdown_complete should show activeTasks back to 0
    const completeEvent = events.find((e) => e.event === "shutdown_complete");
    expect(completeEvent?.activeTasks).toBe(0);

    expect(exitCode).toBe(0);

    // Clean up
    redis.disconnect();
    mock.server.close();
  }, 60_000);
});
