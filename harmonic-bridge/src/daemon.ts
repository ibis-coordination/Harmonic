// Daemon entrypoint. Loads daemon + per-agent configs, wires the server,
// the dispatcher, and the wake-spawn together. Returns a handle the caller
// can stop() for graceful shutdown, or reload() to re-read per-agent
// configs without dropping in-flight wakes.
//
// Everything below this point is composition — no business logic. The
// pieces are exercised independently by their own tests; this module's
// tests cover the wiring end-to-end.

import { promises as fs } from "node:fs";
import path from "node:path";
import type { Writable } from "node:stream";
import {
  listAgentNames,
  loadAgentConfig,
  loadDaemonConfig,
} from "./config-loader.js";
import { parseReference, resolveSecret } from "./secrets.js";
import { spawnWake } from "./spawn.js";
import { createDispatcher } from "./dispatcher.js";
import { startServer } from "./server.js";
import { openAgentLogStreams } from "./log-streams.js";
import { createHoldAwake } from "./hold-awake.js";
import type { AgentConfig } from "./config.js";

export interface DaemonOpts {
  /** Base config directory. Typically ~/.harmonic-bridge. */
  readonly configDir: string;
  /** Override the daemon-config listen address (useful for tests on port 0). */
  readonly listenOverride?: { readonly host: string; readonly port: number };
  /**
   * If true, write a PID file at `${configDir}/daemon.pid` on start and
   * install a SIGHUP handler that reloads per-agent configs. Defaults to
   * false; production callers (the CLI) pass true. Tests leave it off to
   * avoid signal-handler interference across concurrent test runs.
   */
  readonly installSignalHandlers?: boolean;
  /**
   * Test override for hold-awake timing (prime grace). Production callers
   * leave this unset and get the defaults.
   */
  readonly holdOverrides?: { readonly primeGraceMs?: number };
  /**
   * Where per-wake lifecycle lines (spawned / exit code / spawn errors) are
   * written. Defaults to process.stdout, which the host's service
   * supervisor captures. Wake commands' own output goes to the per-agent
   * log files, not here.
   */
  readonly logStream?: Writable;
}

export interface RunningDaemon {
  readonly port: number;
  /** Re-read per-agent configs and update the in-memory map. */
  reload(): Promise<void>;
  /** Graceful shutdown — stops accepting webhooks, drains in-flight wakes. */
  stop(): Promise<void>;
}

interface WakeEvent {
  readonly eventType: string;
  readonly payload: string;
}

/**
 * How long a webhook ack may wait for the hold-awake connection to
 * establish. Comfortably inside Harmonic's 30s delivery timeout; if the
 * hold can't establish by then the ack proceeds anyway.
 */
const HOLD_PRIME_TIMEOUT_MS = 2_000;

export async function startDaemon(opts: DaemonOpts): Promise<RunningDaemon> {
  const daemon = await loadDaemonConfig(path.join(opts.configDir, "config.yml"));

  const agentsDir = path.join(opts.configDir, "agents");
  const agents = new Map<string, AgentConfig>();

  async function loadAllAgents(): Promise<void> {
    const names = await listAgentNames(agentsDir);
    const seen = new Set(names);
    for (const name of names) {
      try {
        const cfg = await loadAgentConfig(path.join(agentsDir, name, "harmonic-bridge.yml"));
        agents.set(name, cfg);
      } catch (e) {
        // One bad config shouldn't take down the daemon's view of healthy
        // agents. Surface the error and skip; the agent stays absent from
        // the map (so its webhooks 404 until the config is fixed).
        const msg = e instanceof Error ? e.message : String(e);
        process.stderr.write(`harmonic-bridge: failed to load agent "${name}": ${msg}\n`);
      }
    }
    for (const name of agents.keys()) {
      if (!seen.has(name)) agents.delete(name);
    }
  }

  await loadAllAgents();

  // On hibernating hosts, hold a connection open against our own public URL
  // for the duration of every wake so the platform's idle detector doesn't
  // freeze the machine mid-task. publicUrl presence is enforced by the
  // config parser when the flag is on.
  const holdAwake = daemon.holdAwakeDuringWake
    ? createHoldAwake({
        url: `${(daemon.publicUrl as string).replace(/\/+$/, "")}/hold`,
        primeGraceMs: opts.holdOverrides?.primeGraceMs,
        onError: (e, consecutive) => {
          // First failure and every 40th thereafter — enough to diagnose a
          // dead hold without flooding the log at the reconnect cadence.
          if (consecutive === 1 || consecutive % 40 === 0) {
            const msg = e instanceof Error ? e.message : String(e);
            process.stderr.write(`harmonic-bridge: hold-awake connection failing (attempt ${consecutive}): ${msg}\n`);
          }
        },
      })
    : null;

  const dispatcher = createDispatcher<WakeEvent>(async (handle, { eventType, payload }) => {
    holdAwake?.acquire();
    try {
      await runWake(handle, eventType, payload);
    } finally {
      holdAwake?.release();
    }
  });

  async function runWake(handle: string, eventType: string, payload: string): Promise<void> {
    const cfg = agents.get(handle);
    if (!cfg) return;
    if (cfg.events && !cfg.events.includes(eventType)) return;

    // Inherit the daemon's environment so common tooling works (HOME for
    // ~/.claude.json discovery, LANG for locale-aware output, USER, TERM,
    // PATH, etc.). The per-agent env: block overrides any inherited keys,
    // and the HARMONIC_BRIDGE_* vars are force-set last so neither can shadow them.
    const env: Record<string, string> = {};
    for (const [k, v] of Object.entries(process.env)) {
      if (typeof v === "string") env[k] = v;
    }

    if (cfg.env) {
      for (const [k, v] of Object.entries(cfg.env)) {
        env[k] = await resolveMaybe(v, daemon.secretResolvers);
      }
    }

    const token = await resolveMaybe(cfg.harmonicToken, daemon.secretResolvers);

    // harmonic-bridge standard env — set last so the per-agent env: block can't shadow.
    env["HARMONIC_BRIDGE_AGENT_NAME"] = handle;
    env["HARMONIC_BRIDGE_AGENT_DIR"] = path.join(agentsDir, handle);
    env["HARMONIC_BRIDGE_EVENT_TYPE"] = eventType;
    env["HARMONIC_BRIDGE_MCP_ENDPOINT"] = cfg.harmonicMcpEndpoint;
    env["HARMONIC_BRIDGE_TOKEN"] = token;

    const logs = await openAgentLogStreams(daemon.logDir, handle);
    logLine(`wake ${handle} event=${eventType} spawned`);
    try {
      const result = await spawnWake({
        command: cfg.wakeCommand,
        cwd: cfg.workingDir,
        env,
        stdin: payload,
        timeoutSeconds: cfg.timeoutSeconds,
        stdout: logs.stdout,
        stderr: logs.stderr,
      });
      const signalNote = result.signal ? ` signal=${result.signal}` : "";
      const timeoutNote = result.timedOut ? " timed_out" : "";
      logLine(`wake ${handle} exit=${result.exitCode ?? "none"}${signalNote}${timeoutNote} duration_ms=${result.durationMs}`);
    } catch (e) {
      // spawnWake rejects only when the process couldn't be spawned at all.
      logLine(`wake ${handle} spawn_error=${e instanceof Error ? e.message : String(e)}`);
    } finally {
      await logs.close();
    }
  }

  function logLine(message: string): void {
    (opts.logStream ?? process.stdout).write(`harmonic-bridge: ${message}\n`);
  }

  const server = await startServer({
    listen: opts.listenOverride ?? daemon.listen,
    holdRoute: daemon.holdAwakeDuringWake ? { heartbeatMs: 10_000 } : undefined,
    beforeAck: holdAwake ? () => holdAwake.prime(HOLD_PRIME_TIMEOUT_MS) : undefined,
    resolveAgent: async (handle) => {
      const cfg = agents.get(handle);
      if (!cfg) return null;
      const webhookSecret = await resolveMaybe(cfg.webhookSecret, daemon.secretResolvers);
      return { webhookSecret };
    },
    onEvent: (handle, eventType, payload) => {
      dispatcher.dispatch(handle, { eventType, payload });
    },
  });

  const pidFilePath = path.join(opts.configDir, "daemon.pid");
  let pidFileWritten = false;
  let sighupHandler: (() => void) | undefined;

  if (opts.installSignalHandlers) {
    await fs.writeFile(pidFilePath, String(process.pid), "utf8");
    pidFileWritten = true;

    sighupHandler = () => {
      // Fire-and-forget; errors are logged inside loadAllAgents.
      loadAllAgents().catch((e) => {
        const msg = e instanceof Error ? e.message : String(e);
        process.stderr.write(`harmonic-bridge: reload failed: ${msg}\n`);
      });
    };
    process.on("SIGHUP", sighupHandler);
  }

  let stopped = false;
  return {
    port: server.port,
    reload: loadAllAgents,
    stop: async () => {
      if (stopped) return;
      stopped = true;
      if (sighupHandler) process.off("SIGHUP", sighupHandler);
      // Stop accepting new connections immediately, but don't await yet:
      // close() resolves only when existing connections end, and in
      // production the hold-awake connection hairpins back into this same
      // server — it closes when the drained wakes release it.
      const closing = server.close();
      await dispatcher.drain();
      if (holdAwake) await holdAwake.stop();
      await closing;
      if (pidFileWritten) {
        await fs.unlink(pidFilePath).catch(() => undefined);
      }
    },
  };
}

/** Resolve a value that may be either a secret reference or a literal string. */
async function resolveMaybe(value: string, resolvers: Readonly<Record<string, string>>): Promise<string> {
  return parseReference(value) === null ? value : resolveSecret(value, resolvers);
}
