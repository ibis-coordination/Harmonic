// Daemon entrypoint. Loads daemon + per-agent configs, wires the server,
// the dispatcher, and the wake-spawn together. Returns a handle the caller
// can stop() for graceful shutdown.
//
// Everything below this point is composition — no business logic. The
// pieces are exercised independently by their own tests; this module's
// tests cover the wiring end-to-end.

import path from "node:path";
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
import type { AgentConfig } from "./config.js";

export interface DaemonOpts {
  /** Base config directory. Typically ~/.harmonic-bridge. */
  readonly configDir: string;
  /** Override the daemon-config listen address (useful for tests on port 0). */
  readonly listenOverride?: { readonly host: string; readonly port: number };
}

export interface RunningDaemon {
  readonly port: number;
  stop(): Promise<void>;
}

interface WakeEvent {
  readonly eventType: string;
  readonly payload: string;
}

export async function startDaemon(opts: DaemonOpts): Promise<RunningDaemon> {
  const daemon = await loadDaemonConfig(path.join(opts.configDir, "config.yml"));

  const agentsDir = path.join(opts.configDir, "agents");
  const agents = new Map<string, AgentConfig>();
  for (const name of await listAgentNames(agentsDir)) {
    const agentDir = path.join(agentsDir, name);
    const cfg = await loadAgentConfig(path.join(agentDir, "harmonic-bridge.yml"));
    agents.set(name, cfg);
  }

  const dispatcher = createDispatcher<WakeEvent>(async (handle, { eventType, payload }) => {
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
    try {
      await spawnWake({
        command: cfg.wakeCommand,
        cwd: cfg.workingDir,
        env,
        stdin: payload,
        timeoutSeconds: cfg.timeoutSeconds,
        stdout: logs.stdout,
        stderr: logs.stderr,
      });
    } finally {
      await logs.close();
    }
  });

  const server = await startServer({
    listen: opts.listenOverride ?? daemon.listen,
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

  let stopped = false;
  return {
    port: server.port,
    stop: async () => {
      if (stopped) return;
      stopped = true;
      await server.close();
      await dispatcher.drain();
    },
  };
}

/** Resolve a value that may be either a secret reference or a literal string. */
async function resolveMaybe(value: string, resolvers: Readonly<Record<string, string>>): Promise<string> {
  return parseReference(value) === null ? value : resolveSecret(value, resolvers);
}
