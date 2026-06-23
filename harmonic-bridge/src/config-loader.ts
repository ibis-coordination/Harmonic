// Filesystem layer on top of the pure parsers in ./config.
//
// Reads YAML from disk, parses via parseDaemonConfig / parseAgentConfig,
// and expands `~` in path fields so config files can use the same paths
// the README shows. Throws ConfigError on file-not-found, YAML errors, or
// parse failures — callers see one error type regardless of which layer
// failed.

import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { parse as parseYaml } from "yaml";
import {
  AgentConfig,
  ConfigError,
  DaemonConfig,
  parseAgentConfig,
  parseDaemonConfig,
} from "./config.js";

/** Replace a leading `~` with $HOME. Non-leading tildes are left alone. */
export function expandTilde(value: string): string {
  if (value === "~") return homedir();
  if (value.startsWith("~/")) return path.join(homedir(), value.slice(2));
  return value;
}

export async function loadDaemonConfig(filePath: string): Promise<DaemonConfig> {
  const content = await readFileOrThrow(filePath);
  const raw = parseYamlOrThrow(content, filePath);
  const parsed = parseDaemonConfig(raw);
  return Object.freeze({
    ...parsed,
    logDir: expandTilde(parsed.logDir),
  });
}

export async function loadAgentConfig(filePath: string): Promise<AgentConfig> {
  const content = await readFileOrThrow(filePath);
  const raw = parseYamlOrThrow(content, filePath);
  const parsed = parseAgentConfig(raw);
  return Object.freeze({
    ...parsed,
    workingDir: expandTilde(parsed.workingDir),
  });
}

/**
 * List subdirectory names under `agentsBaseDir` that contain a `harmonic-bridge.yml`.
 * Returns an empty array if `agentsBaseDir` does not exist (the convention
 * is that no configured agents == an empty agents dir).
 */
export async function listAgentNames(agentsBaseDir: string): Promise<string[]> {
  let entries;
  try {
    entries = await fs.readdir(agentsBaseDir, { withFileTypes: true });
  } catch (e) {
    if (isNodeError(e) && e.code === "ENOENT") return [];
    throw e;
  }
  const names: string[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const cfgPath = path.join(agentsBaseDir, entry.name, "harmonic-bridge.yml");
    try {
      await fs.access(cfgPath);
      names.push(entry.name);
    } catch {
      // No harmonic-bridge.yml in this directory — not an agent dir, skip.
    }
  }
  return names.sort();
}

// ---------- internal helpers ----------

async function readFileOrThrow(filePath: string): Promise<string> {
  try {
    return await fs.readFile(filePath, "utf8");
  } catch (e) {
    if (isNodeError(e) && e.code === "ENOENT") {
      throw new ConfigError(`Config file not found: ${filePath}`);
    }
    const detail = e instanceof Error ? e.message : String(e);
    throw new ConfigError(`Could not read ${filePath}: ${detail}`);
  }
}

function parseYamlOrThrow(content: string, filePath: string): unknown {
  try {
    return parseYaml(content);
  } catch (e) {
    const detail = e instanceof Error ? e.message : String(e);
    throw new ConfigError(`YAML error in ${filePath}: ${detail}`);
  }
}

function isNodeError(e: unknown): e is NodeJS.ErrnoException {
  return e instanceof Error && "code" in e;
}
