// Generate a per-agent Goose config.
//
// Goose reads one config file per config root, and every extension in it loads
// in every session. Writing the Harmonic extension into the operator's shared
// `~/.config/goose/config.yaml` would therefore load every agent's extension in
// every wake, while only the current wake's token is in scope — so all but one
// would fail to authenticate on every run. Instead each agent gets its own
// config root inside its agent dir, and the wake command points Goose at it by
// exporting both HOME and XDG_CONFIG_HOME.
//
// That relocation is safe here in a way it would not be for Codex: Goose
// deliberately does not read provider credentials from config.yaml — they come
// from the environment — so moving the config root strands no credentials.
//
// The token is written as a literal `${HARMONIC_BRIDGE_TOKEN}` reference. Goose
// substitutes environment variables in extension header values at session
// start, so harmonic-bridge never writes the resolved secret to disk.

import { promises as fs } from "node:fs";
import path from "node:path";
import { parseDocument, isMap, Scalar } from "yaml";

/** Timeout Goose applies to the extension's requests, in seconds. */
const EXTENSION_TIMEOUT_SECONDS = 300;

export interface WriteGooseConfigArgs {
  readonly agentDir: string;
  readonly agentHandle: string;
  readonly mcpEndpoint: string;
}

/**
 * The XDG config root for an agent — the value the wake command exports as
 * XDG_CONFIG_HOME, and `$HOME/.config` for the HOME it exports alongside it.
 */
export function gooseConfigRoot(agentDir: string): string {
  return path.join(agentDir, "home", ".config");
}

export async function writeGooseConfig(args: WriteGooseConfigArgs): Promise<string> {
  const dir = path.join(gooseConfigRoot(args.agentDir), "goose");
  const filePath = path.join(dir, "config.yaml");
  await fs.mkdir(dir, { recursive: true });

  // Merge rather than overwrite: this file is a whole config root, so it may
  // carry the operator's own extensions and settings. parseDocument preserves
  // their comments and formatting for everything we don't touch.
  const existing = await readIfPresent(filePath);
  const doc = parseDocument(existing ?? "");
  if (doc.contents !== null && !isMap(doc.contents)) {
    throw new Error(`${filePath} is not a YAML mapping; refusing to overwrite it`);
  }

  doc.setIn(["extensions", `harmonic-${args.agentHandle}`], {
    enabled: true,
    type: "streamable_http",
    name: `harmonic-${args.agentHandle}`,
    uri: args.mcpEndpoint,
    headers: { Authorization: quoted("Bearer ${HARMONIC_BRIDGE_TOKEN}") },
    // Header substitution draws only from the extension's envs/env_keys pool,
    // not the raw process env. env_keys admits the variable into that pool;
    // goose's secret lookup checks the process environment first, so the
    // value still comes from the wake env and never from disk.
    env_keys: ["HARMONIC_BRIDGE_TOKEN"],
    timeout: EXTENSION_TIMEOUT_SECONDS,
  });

  await fs.writeFile(filePath, doc.toString(), "utf8");
  return filePath;
}

/**
 * Emit a double-quoted scalar. A plain `Bearer ${VAR}` is a legal YAML scalar
 * and round-trips through our own parser, but quoting removes any question of
 * how a different YAML implementation reads the brace.
 */
function quoted(value: string): Scalar {
  const node = new Scalar(value);
  node.type = Scalar.QUOTE_DOUBLE;
  return node;
}

async function readIfPresent(filePath: string): Promise<string | undefined> {
  try {
    return await fs.readFile(filePath, "utf8");
  } catch (e) {
    if (e instanceof Error && "code" in e && (e as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw e;
  }
}
