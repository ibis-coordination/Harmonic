// `harmonic-bridge add --from <URL>` — exchange a one-time setup URL for a
// running agent on this host. Talks to Harmonic's /bridge-setups endpoints,
// stores the minted credentials, writes the per-agent config, sighups the
// running daemon, and runs any configured after_add steps.
//
// Flow:
//   1. POST <URL> → metadata + token + signing_secret. POST (not GET) so
//      a stray browser visit or link-preview fetch can't burn the
//      redemption — both Harmonic-side endpoints mint credentials.
//   2. Write secrets via the configured backend (v0.1: file://) at mode 0600
//   3. Write per-agent config with secret references + stub wake_command
//   4. SIGHUP the daemon so it picks up the new agent before Harmonic's
//      synchronous verification POST arrives during step 5
//   5. POST webhook_register_url with {webhook_url, events}
//   6. On success: run after_add steps, print "edit wake_command" summary
//   7. On any failure after step 2: roll back local files + sighup daemon
//      again so it drops the now-deleted agent
//
// Errors are surfaced as actionable messages — the bridge often has better
// diagnostics than Harmonic (DNS, TLS, public_url misconfiguration) and
// should say so explicitly.

import { promises as fs } from "node:fs";
import path from "node:path";
import type { Writable } from "node:stream";
import { stringify as stringifyYaml } from "yaml";
import { loadDaemonConfig } from "./config-loader.js";
import { runSteps, type StepContext } from "./steps.js";

/** Time-bound the round-trips to Harmonic. */
const HTTP_TIMEOUT_MS = 30_000;

/**
 * Server-side handle constraint — mirrors the daemon's webhook route regex
 * (server.ts ROUTE_RE) and Harmonic's own handle validation. Used to guard
 * against a malicious or buggy Harmonic response trying to escape the
 * intended filesystem location via `agent_handle: "../etc/passwd"` or
 * similar. We treat handles received over the network as untrusted input.
 */
const SAFE_HANDLE_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/;

export interface AddOpts {
  readonly configDir: string;
  readonly stdout?: Writable;
  readonly stderr?: Writable;
  /** Test injection point for HTTP. Defaults to global.fetch. */
  readonly fetch?: typeof fetch;
  /** Test injection point for signal sending. Defaults to process.kill. */
  readonly kill?: (pid: number, signal: NodeJS.Signals) => void;
}

interface SetupMetadata {
  readonly harmonic_mcp_endpoint: string;
  readonly harmonic_token: string;
  readonly signing_secret: string;
  readonly agent_handle: string;
  readonly webhook_register_url: string;
  readonly events_recommended: readonly string[];
}

const USAGE = "Usage: harmonic-bridge add --from <URL>\n";

export async function runAdd(args: readonly string[], opts: AddOpts): Promise<number> {
  const stdout = opts.stdout ?? process.stdout;
  const stderr = opts.stderr ?? process.stderr;
  const doFetch = opts.fetch ?? globalThis.fetch;
  const doKill = opts.kill ?? ((pid: number, sig: NodeJS.Signals) => { process.kill(pid, sig); });

  const fromUrl = parseFromArg(args);
  if (typeof fromUrl !== "string") {
    stderr.write(`harmonic-bridge add: ${fromUrl.error}\n${USAGE}`);
    return 64;
  }

  // 1. Load daemon config + validate public_url
  let daemonConfig;
  try {
    daemonConfig = await loadDaemonConfig(path.join(opts.configDir, "config.yml"));
  } catch (e) {
    stderr.write(`harmonic-bridge add: failed to load daemon config — ${errMessage(e)}\n`);
    stderr.write(`Run 'harmonic-bridge init' if you haven't yet.\n`);
    return 1;
  }
  const publicUrlError = validatePublicUrl(daemonConfig.publicUrl, opts.configDir);
  if (publicUrlError) {
    stderr.write(publicUrlError);
    return 1;
  }
  const publicUrlBase = (daemonConfig.publicUrl as string).replace(/\/+$/, "");

  // 2. POST to redeem the setup URL → metadata + credentials.
  stdout.write(`Redeeming setup URL ${fromUrl}…\n`);
  let metadata: SetupMetadata;
  try {
    const response = await fetchWithTimeout(doFetch, fromUrl, { method: "POST" });
    if (!response.ok) {
      if (response.status === 404) {
        stderr.write(`harmonic-bridge add: setup URL is invalid or expired (404). Click "Connect harmonic-bridge" again for a fresh URL.\n`);
      } else {
        stderr.write(`harmonic-bridge add: POST ${fromUrl} returned ${response.status} ${response.statusText}\n`);
      }
      return 1;
    }
    metadata = (await response.json()) as SetupMetadata;
  } catch (e) {
    if (isAbortError(e)) {
      stderr.write(`harmonic-bridge add: POST ${fromUrl} timed out after ${HTTP_TIMEOUT_MS / 1000}s.\n`);
    } else {
      stderr.write(`harmonic-bridge add: failed to POST ${fromUrl} — ${errMessage(e)}\n`);
    }
    return 1;
  }

  // Treat agent_handle as untrusted network input — reject anything that
  // could escape the intended filesystem layout via path components.
  const handle = metadata.agent_handle;
  if (typeof handle !== "string" || !SAFE_HANDLE_RE.test(handle)) {
    stderr.write(`harmonic-bridge add: Harmonic returned an unsafe agent_handle (${JSON.stringify(handle)}). Refusing to proceed.\n`);
    return 1;
  }

  const agentDir = path.join(opts.configDir, "agents", handle);
  const webhookUrl = `${publicUrlBase}/webhook/${encodeURIComponent(handle)}`;
  const secretsBaseDir = daemonConfig.secrets.baseDir;

  // 3. Write secrets to disk via the configured backend.
  let tokenPath: string;
  let secretPath: string;
  try {
    const secretsDir = path.join(secretsBaseDir, handle);
    await fs.mkdir(secretsDir, { recursive: true, mode: 0o700 });
    tokenPath = path.join(secretsDir, "harmonic_token");
    secretPath = path.join(secretsDir, "webhook_secret");
    await fs.writeFile(tokenPath, metadata.harmonic_token, { mode: 0o600 });
    await fs.writeFile(secretPath, metadata.signing_secret, { mode: 0o600 });
  } catch (e) {
    stderr.write(`harmonic-bridge add: failed to write secrets — ${errMessage(e)}\n`);
    return 1;
  }

  // 4. Write per-agent config.
  try {
    await fs.mkdir(agentDir, { recursive: true });
    await fs.writeFile(
      path.join(agentDir, "harmonic-bridge.yml"),
      renderAgentYaml({ mcpEndpoint: metadata.harmonic_mcp_endpoint, tokenPath, secretPath, events: metadata.events_recommended, handle, agentDir }),
      { flag: "wx" },
    );
  } catch (e) {
    if (isNodeError(e) && e.code === "EEXIST") {
      stderr.write(`harmonic-bridge add: agent "${handle}" is already configured at ${agentDir}. Remove it before re-adding.\n`);
      await cleanupSecrets(secretsBaseDir, handle);
      return 1;
    }
    stderr.write(`harmonic-bridge add: failed to write agent config — ${errMessage(e)}\n`);
    await cleanupSecrets(secretsBaseDir, handle);
    return 1;
  }

  // 5. SIGHUP the daemon so it loads the new agent + secret BEFORE Harmonic's
  //    verification POST fires (step 6). If the daemon isn't running, we
  //    can't proceed — Harmonic's verification would 404 against an unknown
  //    handle, registration would fail, and we'd just have to clean up
  //    again. Better to bail now with a clear instruction.
  const sighup = await sendSighup(opts.configDir, doKill);
  if (!sighup.ok) {
    stderr.write(`harmonic-bridge add: ${sighup.error}\n`);
    stderr.write(`The daemon needs to be running so it can receive Harmonic's verification POST.\nStart it with 'harmonic-bridge' and retry.\n`);
    await cleanupAgent(opts.configDir, secretsBaseDir, handle);
    return 1;
  }

  // 6. POST to Harmonic to register the webhook.
  stdout.write(`Registering ${webhookUrl} with Harmonic…\n`);
  try {
    const response = await fetchWithTimeout(doFetch, metadata.webhook_register_url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ webhook_url: webhookUrl, events: metadata.events_recommended }),
    });
    if (!response.ok) {
      await writeRegistrationError(stderr, response, webhookUrl, daemonConfig);
      await cleanupAgent(opts.configDir, secretsBaseDir, handle);
      await sendSighup(opts.configDir, doKill);  // tell daemon to drop the now-deleted agent
      return 1;
    }
  } catch (e) {
    if (isAbortError(e)) {
      stderr.write(`harmonic-bridge add: POST to ${metadata.webhook_register_url} timed out after ${HTTP_TIMEOUT_MS / 1000}s.\n`);
    } else {
      stderr.write(`harmonic-bridge add: POST to register webhook failed — ${errMessage(e)}\n`);
    }
    await cleanupAgent(opts.configDir, secretsBaseDir, handle);
    await sendSighup(opts.configDir, doKill);
    return 1;
  }

  // 7. Run after_add steps.
  if (daemonConfig.afterAdd.length > 0) {
    stdout.write(`Running after_add steps…\n`);
    const ctx: StepContext = {
      agentHandle: handle,
      agentDir,
      mcpEndpoint: metadata.harmonic_mcp_endpoint,
      token: metadata.harmonic_token,
    };
    await runSteps(daemonConfig.afterAdd, ctx, {
      stdout,
      stderr,
      onResult: (step, result) => {
        const tag = step.kind === "command" ? `command: ${step.command.slice(0, 60)}` : `built_in: ${step.name}`;
        if (result.ok) stdout.write(`  ok   ${tag}\n`);
        else stderr.write(`  FAIL ${tag} — ${result.error}\n`);
      },
    });
  }

  // 8. Done.
  stdout.write(`\nAgent "${handle}" added.\n`);
  stdout.write(`\nNext steps:\n`);
  stdout.write(`  1. Edit wake_command in ${path.join(agentDir, "harmonic-bridge.yml")} so the agent\n`);
  stdout.write(`     does something useful when notifications arrive.\n`);
  stdout.write(`  2. Run 'harmonic-bridge reload' (or restart the daemon) to pick up your changes.\n`);
  return 0;
}

function parseFromArg(args: readonly string[]): string | { error: string } {
  const i = args.indexOf("--from");
  if (i === -1) return { error: "missing --from <URL>" };
  const v = args[i + 1];
  if (!v) return { error: "--from requires a URL argument" };
  try {
    new URL(v);
  } catch {
    return { error: `--from value is not a valid URL: ${v}` };
  }
  return v;
}

function validatePublicUrl(publicUrl: string | undefined, configDir: string): string | null {
  if (!publicUrl) {
    return (
      `harmonic-bridge add: public_url is not set in ${path.join(configDir, "config.yml")}.\n` +
      `Set it to the publicly-reachable HTTPS URL your reverse proxy or tunnel forwards to\n` +
      `this daemon (e.g. https://bridge.example.com), then retry.\n`
    );
  }
  let u: URL;
  try {
    u = new URL(publicUrl);
  } catch {
    return `harmonic-bridge add: public_url is not a valid URL: ${publicUrl}\n`;
  }
  if (u.protocol !== "https:") {
    return `harmonic-bridge add: public_url must use https:// (got ${u.protocol}//). Harmonic only delivers webhooks over TLS.\n`;
  }
  return null;
}

async function writeRegistrationError(
  stderr: Writable,
  response: Response,
  webhookUrl: string,
  daemonConfig: { publicUrl?: string; listen: { host: string; port: number } },
): Promise<void> {
  let body: { error?: string; detail?: string } = {};
  try {
    body = (await response.json()) as { error?: string; detail?: string };
  } catch {
    // body wasn't JSON — fall through with empty body
  }
  if (response.status === 422 && body.error === "webhook_unreachable") {
    stderr.write(`harmonic-bridge add: Harmonic's verification POST didn't get a 2xx from ${webhookUrl}.\n`);
    if (body.detail) stderr.write(`  detail: ${body.detail}\n`);
    stderr.write(`\nLikely causes:\n`);
    stderr.write(`  - public_url (${daemonConfig.publicUrl}) is not actually reachable from the public internet\n`);
    stderr.write(`  - the reverse proxy / tunnel isn't forwarding to the daemon's listen port (${daemonConfig.listen.host}:${daemonConfig.listen.port})\n`);
    stderr.write(`  - TLS isn't terminated correctly at the public URL\n`);
    stderr.write(`  - a firewall blocks Harmonic from reaching your host\n`);
    return;
  }
  if (response.status === 404) {
    stderr.write(`harmonic-bridge add: setup URL is consumed or expired (404). Click "Connect harmonic-bridge" again for a fresh URL.\n`);
    return;
  }
  const detail = body.detail ?? body.error ?? response.statusText;
  stderr.write(`harmonic-bridge add: registration failed (${response.status}) — ${detail}\n`);
}

function renderAgentYaml(f: {
  mcpEndpoint: string;
  tokenPath: string;
  secretPath: string;
  events: readonly string[];
  handle: string;
  agentDir: string;
}): string {
  // Use the yaml library to safely encode scalar values that originate from
  // outside the bridge (Harmonic-supplied URLs, filesystem paths). Without
  // this, an MCP endpoint URL containing '#' would be truncated at the YAML
  // comment marker; other YAML-special chars (&, *, [, ], unbalanced :) would
  // be similarly mis-parsed. The hand-formatted structure stays so the
  // explanatory comments survive.
  const eventsYaml = f.events.map((e) => `  - ${ymlScalar(e)}`).join("\n");
  return `# harmonic-bridge agent config for "${f.handle}" — generated by 'harmonic-bridge add'.
# Edit wake_command and working_dir before relying on this agent.

harmonic_mcp_endpoint: ${ymlScalar(f.mcpEndpoint)}
harmonic_token: ${ymlScalar(`file://${f.tokenPath}`)}
webhook_secret: ${ymlScalar(`file://${f.secretPath}`)}

# Where the wake command runs. Defaults to the agent's own config dir so the
# daemon loads cleanly out of the box; change this to wherever your harness
# expects cwd before relying on the agent.
working_dir: ${ymlScalar(f.agentDir)}

# What to run when a notification arrives. The payload arrives on stdin;
# HARMONIC_BRIDGE_AGENT_NAME, AGENT_DIR, EVENT_TYPE, MCP_ENDPOINT, and TOKEN
# are set in the env. The stub below exits non-zero so a misconfigured agent
# fails loudly instead of silently dropping notifications.
wake_command: |
  echo "wake_command not configured for $HARMONIC_BRIDGE_AGENT_NAME" >&2
  exit 1

events:
${eventsYaml}
`;
}

/** Stringify a single scalar value, trimming the trailing newline yaml v2 adds. */
function ymlScalar(v: string): string {
  return stringifyYaml(v).trimEnd();
}

async function sendSighup(
  configDir: string,
  kill: (pid: number, sig: NodeJS.Signals) => void,
): Promise<{ ok: true } | { ok: false; error: string }> {
  const pidFilePath = path.join(configDir, "daemon.pid");
  let pidRaw: string;
  try {
    pidRaw = await fs.readFile(pidFilePath, "utf8");
  } catch (e) {
    if (isNodeError(e) && e.code === "ENOENT") {
      return { ok: false, error: `daemon not running (no PID file at ${pidFilePath})` };
    }
    return { ok: false, error: `failed to read ${pidFilePath}: ${errMessage(e)}` };
  }
  const pid = Number(pidRaw.trim());
  if (!Number.isInteger(pid) || pid <= 0) {
    return { ok: false, error: `${pidFilePath} contains "${pidRaw.trim()}", not a valid PID` };
  }
  try {
    kill(pid, "SIGHUP");
  } catch (e) {
    if (isNodeError(e) && e.code === "ESRCH") {
      return { ok: false, error: `no process with PID ${pid} (daemon.pid is stale; remove it and start the daemon)` };
    }
    if (isNodeError(e) && e.code === "EPERM") {
      return { ok: false, error: `not permitted to signal PID ${pid} — is the daemon running as a different user?` };
    }
    return { ok: false, error: `failed to send SIGHUP to PID ${pid}: ${errMessage(e)}` };
  }
  return { ok: true };
}

async function cleanupSecrets(secretsBaseDir: string, handle: string): Promise<void> {
  await fs.rm(path.join(secretsBaseDir, handle), { recursive: true, force: true }).catch(() => undefined);
}

async function cleanupAgent(configDir: string, secretsBaseDir: string, handle: string): Promise<void> {
  await fs.rm(path.join(configDir, "agents", handle), { recursive: true, force: true }).catch(() => undefined);
  await cleanupSecrets(secretsBaseDir, handle);
}

function isNodeError(e: unknown): e is NodeJS.ErrnoException {
  return e instanceof Error && "code" in e;
}

function errMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

function isAbortError(e: unknown): boolean {
  return e instanceof Error && e.name === "AbortError";
}

/** Wraps fetch with an AbortController so a hung Harmonic can't pin the CLI. */
async function fetchWithTimeout(
  doFetch: typeof fetch,
  input: string,
  init: RequestInit,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HTTP_TIMEOUT_MS);
  try {
    return await doFetch(input, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}
