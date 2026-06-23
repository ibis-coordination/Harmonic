// Config parsing for harmonic-bridge.
//
// Parse functions are pure — they take an already-deserialized YAML value
// (unknown shape) and return typed config objects, throwing ConfigError on
// invalid input. Loading from disk is a separate concern (lands in a
// follow-up commit) so these stay easy to test and reuse from CLI commands
// that hold YAML in memory.

import type { Step } from "./steps.js";

export interface DaemonConfig {
  readonly listen: { readonly host: string; readonly port: number };
  readonly logDir: string;
  readonly secretResolvers: Readonly<Record<string, string>>;
  /** Default after-add steps applied to every agent unless the agent overrides. */
  readonly afterAdd: readonly Step[];
}

export interface AgentConfig {
  readonly harmonicMcpEndpoint: string;
  readonly harmonicToken: string;
  readonly webhookSecret: string;
  readonly workingDir: string;
  readonly wakeCommand: string;
  readonly events?: readonly string[];
  readonly timeoutSeconds?: number;
  readonly env?: Readonly<Record<string, string>>;
  /**
   * Override for the daemon's default after-add steps. `undefined` means
   * inherit; an explicit empty list overrides to no steps.
   */
  readonly afterAdd?: readonly Step[];
}

export class ConfigError extends Error {
  override readonly name = "ConfigError";
}

// Always available, regardless of whether the daemon config sets
// `secret_resolvers`. User config may override these or add new schemes.
export const BUILTIN_RESOLVERS: Readonly<Record<string, string>> = Object.freeze({
  file: "cat {path}",
  env: "printenv {name}",
});

export function parseDaemonConfig(raw: unknown): DaemonConfig {
  if (!isRecord(raw)) {
    throw new ConfigError("daemon config must be a YAML object");
  }

  const listen = parseListen(raw["listen"]);
  const logDir = expectString(raw, "log_dir");
  const secretResolvers = parseSecretResolvers(raw["secret_resolvers"]);
  const afterAdd = "after_add" in raw ? parseStepList(raw["after_add"], "after_add") : Object.freeze([]);

  return Object.freeze({ listen, logDir, secretResolvers, afterAdd });
}

export function parseAgentConfig(raw: unknown): AgentConfig {
  if (!isRecord(raw)) {
    throw new ConfigError("agent config must be a YAML object");
  }

  const harmonicMcpEndpoint = expectString(raw, "harmonic_mcp_endpoint");
  validateUrl(harmonicMcpEndpoint, "harmonic_mcp_endpoint");

  const harmonicToken = expectString(raw, "harmonic_token");
  const webhookSecret = expectString(raw, "webhook_secret");
  const workingDir = expectString(raw, "working_dir");
  const wakeCommand = expectString(raw, "wake_command");

  const events = "events" in raw ? parseStringArray(raw["events"], "events") : undefined;
  const timeoutSeconds = "timeout_seconds" in raw
    ? parsePositiveNumber(raw["timeout_seconds"], "timeout_seconds")
    : undefined;
  const env = "env" in raw ? parseStringMap(raw["env"], "env") : undefined;
  // `undefined` (field absent) means inherit daemon defaults; `[]` (explicit
  // empty list) means override to no steps.
  const afterAdd = "after_add" in raw ? parseStepList(raw["after_add"], "after_add") : undefined;

  return Object.freeze({
    harmonicMcpEndpoint,
    harmonicToken,
    webhookSecret,
    workingDir,
    wakeCommand,
    events,
    timeoutSeconds,
    env,
    afterAdd,
  });
}

// ---------- internal helpers ----------

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function expectString(obj: Record<string, unknown>, key: string): string {
  const v = obj[key];
  if (typeof v !== "string" || v.length === 0) {
    throw new ConfigError(`${key} must be a non-empty string`);
  }
  return v;
}

function parseListen(v: unknown): { host: string; port: number } {
  if (typeof v !== "string" || v.length === 0) {
    throw new ConfigError("listen must be a string of the form host:port");
  }
  const idx = v.lastIndexOf(":");
  if (idx < 1) {
    throw new ConfigError(`listen "${v}" must be of the form host:port`);
  }
  const host = v.slice(0, idx);
  const portStr = v.slice(idx + 1);
  const port = Number(portStr);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new ConfigError(`listen port "${portStr}" must be an integer between 1 and 65535`);
  }
  return { host, port };
}

function parseSecretResolvers(v: unknown): Record<string, string> {
  const out: Record<string, string> = { ...BUILTIN_RESOLVERS };
  if (v === undefined || v === null) return out;
  if (!isRecord(v)) {
    throw new ConfigError("secret_resolvers must be a map of scheme to command template");
  }
  for (const [scheme, cmd] of Object.entries(v)) {
    if (!/^[a-z][a-z0-9+\-.]*$/i.test(scheme)) {
      throw new ConfigError(`secret_resolvers scheme "${scheme}" must match URI scheme format`);
    }
    if (typeof cmd !== "string" || cmd.length === 0) {
      throw new ConfigError(`secret_resolvers["${scheme}"] must be a non-empty command template`);
    }
    out[scheme] = cmd;
  }
  return out;
}

function parseStringArray(v: unknown, name: string): readonly string[] {
  if (!Array.isArray(v)) {
    throw new ConfigError(`${name} must be an array of strings`);
  }
  for (const item of v) {
    if (typeof item !== "string") {
      throw new ConfigError(`${name} must contain only strings`);
    }
  }
  return Object.freeze([...v]);
}

function parsePositiveNumber(v: unknown, name: string): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v <= 0) {
    throw new ConfigError(`${name} must be a positive number`);
  }
  return v;
}

function parseStringMap(v: unknown, name: string): Readonly<Record<string, string>> {
  if (!isRecord(v)) {
    throw new ConfigError(`${name} must be a map of string to string`);
  }
  const out: Record<string, string> = {};
  for (const [k, val] of Object.entries(v)) {
    if (typeof val !== "string") {
      throw new ConfigError(`${name}["${k}"] must be a string`);
    }
    out[k] = val;
  }
  return Object.freeze(out);
}

function validateUrl(s: string, name: string): void {
  try {
    new URL(s);
  } catch {
    throw new ConfigError(`${name} must be a valid URL, got "${s}"`);
  }
}

function parseStepList(v: unknown, name: string): readonly Step[] {
  if (v === undefined || v === null) return Object.freeze([]);
  if (!Array.isArray(v)) {
    throw new ConfigError(`${name} must be a list of step objects`);
  }
  return Object.freeze(v.map((item, i) => parseStep(item, name, i)));
}

function parseStep(raw: unknown, listName: string, index: number): Step {
  if (!isRecord(raw)) {
    throw new ConfigError(`${listName}[${index}] must be a YAML object`);
  }
  const hasBuiltIn = "built_in" in raw;
  const hasCommand = "command" in raw;
  if (hasBuiltIn && hasCommand) {
    throw new ConfigError(`${listName}[${index}] must specify exactly one of built_in or command, not both`);
  }
  if (hasBuiltIn) {
    const name = raw["built_in"];
    if (typeof name !== "string" || name.length === 0) {
      throw new ConfigError(`${listName}[${index}].built_in must be a non-empty string`);
    }
    return { kind: "built_in", name };
  }
  if (hasCommand) {
    const command = raw["command"];
    if (typeof command !== "string" || command.length === 0) {
      throw new ConfigError(`${listName}[${index}].command must be a non-empty string`);
    }
    return { kind: "command", command };
  }
  throw new ConfigError(`${listName}[${index}] must specify either built_in or command`);
}
