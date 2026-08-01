// Credential/config loading for harmonic-admin.
//
// Configuration lives in an env-format file (default:
// ~/.config/harmonic-admin/env, chmod 600), overridable per-key by real
// environment variables and wholesale by HARMONIC_ADMIN_CONFIG. The file
// holds read-only, individually-revocable tokens only; nothing in this
// module (or the CLI at large) ever prints a token value.

import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

export const CONFIG_KEYS = [
  "HARMONIC_PROD_URL",
  "HARMONIC_METRICS_TOKEN",
  "SENTRY_API_TOKEN",
  "SENTRY_ORG",
  "SENTRY_PROJECT",
  "SENTRY_BASE_URL",
] as const;

export type ConfigKey = (typeof CONFIG_KEYS)[number];

/** Keys whose values must never be written to any output stream. */
export const SECRET_KEYS: readonly ConfigKey[] = ["HARMONIC_METRICS_TOKEN", "SENTRY_API_TOKEN"];

const DEFAULTS: Partial<Record<ConfigKey, string>> = {
  // The www host, not the apex: the apex 301s to www, and fetch strips
  // Authorization headers on cross-origin redirects, which would break the
  // authenticated /metrics call.
  HARMONIC_PROD_URL: "https://www.harmonic.social",
  SENTRY_BASE_URL: "https://sentry.io",
};

export type ConfigSource = "env" | "file" | "default";

export interface AdminConfig {
  readonly values: Partial<Record<ConfigKey, string>>;
  readonly sources: Partial<Record<ConfigKey, ConfigSource>>;
  /** Resolved path of the env file (whether or not it exists). */
  readonly path: string;
  readonly fileExists: boolean;
}

export interface LoadConfigOpts {
  /** Explicit env file path; wins over HARMONIC_ADMIN_CONFIG and the default. */
  readonly configPath?: string;
  /** Environment map. Defaults to process.env. */
  readonly env?: Record<string, string | undefined>;
}

export function defaultConfigPath(): string {
  return path.join(homedir(), ".config", "harmonic-admin", "env");
}

export async function loadConfig(opts: LoadConfigOpts = {}): Promise<AdminConfig> {
  const env = opts.env ?? process.env;
  const configPath = opts.configPath ?? env.HARMONIC_ADMIN_CONFIG ?? defaultConfigPath();

  let fileValues: Record<string, string> = {};
  let fileExists = false;
  try {
    const raw = await fs.readFile(configPath, "utf8");
    fileExists = true;
    fileValues = parseEnvFile(raw);
  } catch (e) {
    if (!isNodeError(e) || e.code !== "ENOENT") throw e;
  }

  const values: Partial<Record<ConfigKey, string>> = {};
  const sources: Partial<Record<ConfigKey, ConfigSource>> = {};
  for (const key of CONFIG_KEYS) {
    const fromEnv = env[key];
    const fromFile = fileValues[key];
    const fromDefault = DEFAULTS[key];
    if (fromEnv !== undefined && fromEnv !== "") {
      values[key] = fromEnv;
      sources[key] = "env";
    } else if (fromFile !== undefined && fromFile !== "") {
      values[key] = fromFile;
      sources[key] = "file";
    } else if (fromDefault !== undefined) {
      values[key] = fromDefault;
      sources[key] = "default";
    }
  }

  return { values, sources, path: configPath, fileExists };
}

function parseEnvFile(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    const withoutExport = trimmed.startsWith("export ") ? trimmed.slice("export ".length).trim() : trimmed;
    const eq = withoutExport.indexOf("=");
    if (eq <= 0) continue;
    const key = withoutExport.slice(0, eq).trim();
    out[key] = unquote(withoutExport.slice(eq + 1).trim());
  }
  return out;
}

function unquote(value: string): string {
  if (value.length >= 2) {
    const first = value[0];
    if ((first === '"' || first === "'") && value.endsWith(first)) {
      return value.slice(1, -1);
    }
  }
  return value;
}

function isNodeError(e: unknown): e is NodeJS.ErrnoException {
  return e instanceof Error && "code" in e;
}
