// `harmonic-bridge setup-sprite` — one-command setup of a Harmonic agent on
// a Fly Sprite the user owns. Runs on the user's machine (where the
// `sprite` CLI is authenticated) and drives the sprite remotely.
//
// The user flow this automates:
//   sprite: create → install harmonic-bridge → write daemon config
//   (public_url = the sprite's URL, hold_awake_during_wake on) → flip the
//   URL public → run the daemon as a sprite Service → optional harness
//   auth → redeem the bridge-setup URL in-sprite → smoke-probe.
//
// Ordering is load-bearing: the daemon must be running and publicly
// reachable BEFORE `add`, because Harmonic verifies the webhook with a
// synchronous POST during registration. The --from URL is single-use and
// redeemed by POST, so this command never touches it from the laptop —
// it only ever appears in the in-sprite `harmonic-bridge add` invocation.
//
// Harness neutrality: without --harness, the agent is left with the stub
// wake_command and printed instructions — no harness is assumed. Each
// supported --harness value opts into its own after_add steps and auth
// flow via the HARNESSES registry below.

import { spawn as spawnProcess } from "node:child_process";
import type { Writable } from "node:stream";

export interface ExecResult {
  readonly code: number;
  readonly stdout: string;
  readonly stderr: string;
}

/** Run a command, capturing output. */
export type Exec = (argv: readonly string[]) => Promise<ExecResult>;
/** Run a command with the user's terminal attached (interactive auth). */
export type ExecInteractive = (argv: readonly string[]) => Promise<number>;

export interface SetupSpriteOpts {
  readonly stdout?: Writable;
  readonly stderr?: Writable;
  readonly exec?: Exec;
  readonly execInteractive?: ExecInteractive;
  readonly fetch?: typeof fetch;
}

interface HarnessDefinition {
  /** after_add steps this harness contributes to the daemon config. */
  readonly afterAdd: readonly string[];
  /** In-sprite check script: exit 0 when auth already present. */
  readonly authCheckScript: string;
  /** Interactive argv (run on the laptop) to complete auth in the sprite. */
  readonly authCommand: (spriteName: string) => readonly string[];
  readonly authInstructions: string;
}

const HARNESSES: Readonly<Record<string, HarnessDefinition>> = Object.freeze({
  "claude-code": {
    afterAdd: ["claude-code-per-agent-mcp-config", "claude-code-harness"],
    authCheckScript: "test -d /home/sprite/.claude",
    authCommand: (spriteName) => ["sprite", "exec", "-s", spriteName, "--", "claude", "login"],
    authInstructions:
      "Claude Code needs a one-time login inside the sprite. A browser URL will be\nprinted — open it, authorize, and paste the code back.",
  },
});

const DEFAULT_SPRITE_NAME = "harmonic-agent";
const SPRITE_HOME = "/home/sprite";
const BRIDGE_BIN = `${SPRITE_HOME}/.local/bin/harmonic-bridge`;

const USAGE =
  "Usage: harmonic-bridge setup-sprite --from <URL> [--harness <name>] [--sprite-name <name>]\n" +
  `Supported harnesses: ${Object.keys(HARNESSES).join(", ")} (omit --harness to wire your own)\n`;

export async function runSetupSprite(args: readonly string[], opts: SetupSpriteOpts = {}): Promise<number> {
  const stdout = opts.stdout ?? process.stdout;
  const stderr = opts.stderr ?? process.stderr;
  const exec = opts.exec ?? defaultExec;
  const execInteractive = opts.execInteractive ?? defaultExecInteractive;
  const doFetch = opts.fetch ?? globalThis.fetch;

  const parsed = parseArgs(args);
  if ("error" in parsed) {
    stderr.write(`harmonic-bridge setup-sprite: ${parsed.error}\n${USAGE}`);
    return 64;
  }
  const { fromUrl, spriteName, harnessName } = parsed;
  const harness = harnessName ? HARNESSES[harnessName] : undefined;
  if (harnessName && !harness) {
    stderr.write(`harmonic-bridge setup-sprite: unknown harness "${harnessName}".\n${USAGE}`);
    return 64;
  }

  const inSprite = (script: string) => exec(["sprite", "exec", "-s", spriteName, "--", "sh", "-c", script]);

  // 1. Preflight: sprite CLI present + authenticated.
  const list = await exec(["sprite", "list"]);
  if (list.code !== 0) {
    stderr.write(
      `harmonic-bridge setup-sprite: 'sprite list' failed — is the sprite CLI installed and authenticated?\n` +
      `Install: curl -fsSL https://sprites.dev/install.sh | sh\nAuthenticate: sprite login (or 'sprite org auth')\n` +
      `Underlying error: ${(list.stderr || list.stdout).trim()}\n`,
    );
    return 1;
  }

  // 2. Create (or reuse) the sprite.
  const exists = list.stdout.split("\n").map((l) => l.trim()).includes(spriteName);
  if (exists) {
    stdout.write(`Sprite "${spriteName}" already exists — reusing it.\n`);
  } else {
    stdout.write(`Creating sprite "${spriteName}"…\n`);
    const create = await exec(["sprite", "create", spriteName]);
    if (create.code !== 0) return fail(stderr, "sprite create", create);
  }

  // 3. Install harmonic-bridge in the sprite. The nvm-managed global bin
  //    dir is not on PATH for exec/services, so symlink into ~/.local/bin.
  stdout.write("Installing harmonic-bridge in the sprite…\n");
  const install = await inSprite(
    "npm install -g @ibis-coordination/harmonic-bridge >/dev/null 2>&1 && " +
    `ln -sf "$(npm prefix -g)/bin/harmonic-bridge" ${BRIDGE_BIN} && ${BRIDGE_BIN} help >/dev/null`,
  );
  if (install.code !== 0) return fail(stderr, "install harmonic-bridge", install);

  // 4. The sprite's public URL becomes the daemon's public_url.
  const urlResult = await exec(["sprite", "url", "-s", spriteName]);
  const publicUrl = urlResult.stdout.match(/https:\/\/[^\s]+/)?.[0];
  if (urlResult.code !== 0 || !publicUrl) return fail(stderr, "read sprite URL", urlResult);

  // 5. Init + write daemon config.
  stdout.write(`Configuring daemon (public_url ${publicUrl})…\n`);
  const init = await inSprite(`${BRIDGE_BIN} init >/dev/null`);
  if (init.code !== 0) return fail(stderr, "harmonic-bridge init", init);
  const config = renderDaemonConfig(publicUrl, harness?.afterAdd ?? []);
  const writeConfig = await inSprite(remoteWriteScript(`${SPRITE_HOME}/.harmonic-bridge/config.yml`, config));
  if (writeConfig.code !== 0) return fail(stderr, "write daemon config", writeConfig);

  // 6. Public URL + daemon Service — both must precede `add` (Harmonic
  //    verification POSTs synchronously during registration).
  const urlUpdate = await exec(["sprite", "url", "update", "-s", spriteName, "--auth", "public"]);
  if (urlUpdate.code !== 0) return fail(stderr, "make sprite URL public", urlUpdate);

  const services = await inSprite("sprite-env services list");
  if (services.code !== 0) return fail(stderr, "list sprite services", services);
  if (services.stdout.includes('"harmonic-bridge"')) {
    stdout.write("Restarting harmonic-bridge service…\n");
    const restart = await inSprite("sprite-env services restart harmonic-bridge");
    if (restart.code !== 0) return fail(stderr, "restart service", restart);
  } else {
    stdout.write("Creating harmonic-bridge service…\n");
    const create = await inSprite(`sprite-env services create harmonic-bridge --cmd ${BRIDGE_BIN}`);
    if (create.code !== 0) return fail(stderr, "create service", create);
  }

  // 7. Harness auth (only with an explicit --harness).
  if (harness && harnessName) {
    const check = await inSprite(harness.authCheckScript);
    if (check.code !== 0) {
      stdout.write(`\n${harness.authInstructions}\n\n`);
      const authCode = await execInteractive(harness.authCommand(spriteName));
      if (authCode !== 0) {
        stderr.write(`harmonic-bridge setup-sprite: ${harnessName} auth did not complete. Re-run to retry.\n`);
        return 1;
      }
    } else {
      stdout.write(`${harnessName} already authenticated in the sprite.\n`);
    }
  }

  // 8. Redeem the setup URL in-sprite. Single-use: this is the only place
  //    it is ever used, and only once.
  stdout.write("Connecting the agent to Harmonic…\n");
  const add = await inSprite(`${BRIDGE_BIN} add --from ${shellQuote(fromUrl)}`);
  if (add.code !== 0) {
    stderr.write(
      `harmonic-bridge setup-sprite: 'add' failed:\n${indent(add.stderr || add.stdout)}\n` +
      `Setup URLs are single-use. If it was consumed or expired, click "Connect harmonic-bridge"\n` +
      `on the agent's settings page to get a fresh URL, then re-run this command with it.\n`,
    );
    return 1;
  }
  stdout.write(indent(add.stdout.trim()) + "\n");

  // 9. Smoke probe: a GET must reach the daemon and be rejected with 405.
  let probeNote = "";
  try {
    const probe = await doFetch(`${publicUrl}/webhook/probe`, { method: "GET" });
    probeNote = probe.status === 405
      ? `Probe OK: ${publicUrl} reaches the daemon.\n`
      : `Probe WARNING: expected 405 from ${publicUrl}/webhook/probe, got ${probe.status}.\n`;
  } catch (e) {
    probeNote = `Probe WARNING: could not reach ${publicUrl}/webhook/probe — ${e instanceof Error ? e.message : String(e)}\n`;
  }
  stdout.write(probeNote);

  stdout.write("\nDone.\n");
  if (harness) {
    stdout.write("Send your agent a chat message on Harmonic — it should wake and reply.\n");
  } else {
    stdout.write(
      "No harness was configured (--harness not set). The agent's wake_command is a stub:\n" +
      `edit ${SPRITE_HOME}/.harmonic-bridge/agents/<handle>/harmonic-bridge.yml in the sprite\n` +
      "to wire the harness of your choice, then run 'harmonic-bridge reload' there.\n" +
      `Supported presets for a future run: --harness ${Object.keys(HARNESSES).join(", ")}\n`,
    );
  }
  return 0;
}

// ---------- helpers ----------

function parseArgs(args: readonly string[]):
  | { fromUrl: string; spriteName: string; harnessName: string | undefined }
  | { error: string } {
  let fromUrl: string | undefined;
  let spriteName = DEFAULT_SPRITE_NAME;
  let harnessName: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--from") fromUrl = args[++i];
    else if (arg === "--sprite-name") spriteName = args[++i] ?? "";
    else if (arg === "--harness") harnessName = args[++i];
    else return { error: `unexpected argument "${arg}"` };
  }
  if (!fromUrl) return { error: "missing --from <URL>" };
  try {
    const u = new URL(fromUrl);
    if (u.protocol !== "https:") return { error: "--from must be an https:// URL" };
  } catch {
    return { error: `--from value is not a valid URL: ${fromUrl}` };
  }
  if (!/^[a-zA-Z0-9][a-zA-Z0-9-]*$/.test(spriteName)) {
    return { error: `--sprite-name "${spriteName}" must be alphanumeric-with-hyphens` };
  }
  return { fromUrl, spriteName, harnessName };
}

function renderDaemonConfig(publicUrl: string, afterAdd: readonly string[]): string {
  const afterAddBlock = afterAdd.length > 0
    ? "\nafter_add:\n" + afterAdd.map((s) => `  - built_in: ${s}`).join("\n") + "\n"
    : "";
  return `# Written by 'harmonic-bridge setup-sprite'.
listen: 127.0.0.1:8080
public_url: "${publicUrl}"
log_dir: ~/.harmonic-bridge/logs

# Sprites freeze the machine when no connection is open; hold one open
# while wake commands run so in-flight work is never paused.
hold_awake_during_wake: true

secrets:
  backend: file
  base_dir: ~/.harmonic-bridge/secrets
${afterAddBlock}`;
}

/**
 * Script that writes exact file content in-sprite. Base64 round-trip keeps
 * arbitrary content safe inside a single-quoted shell word.
 */
function remoteWriteScript(remotePath: string, content: string): string {
  const b64 = Buffer.from(content, "utf8").toString("base64");
  return `echo '${b64}' | base64 -d > ${remotePath}`;
}

function shellQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function indent(s: string): string {
  return s.split("\n").map((l) => `  ${l}`).join("\n");
}

function fail(stderr: Writable, step: string, result: ExecResult): number {
  stderr.write(
    `harmonic-bridge setup-sprite: step "${step}" failed (exit ${result.code}):\n` +
    indent((result.stderr || result.stdout).trim()) + "\n" +
    "The command is idempotent — fix the issue and re-run.\n",
  );
  return 1;
}

function defaultExec(argv: readonly string[]): Promise<ExecResult> {
  return new Promise((resolve) => {
    const [cmd, ...rest] = argv;
    const child = spawnProcess(cmd!, rest, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (c: Buffer) => (stdout += c.toString()));
    child.stderr?.on("data", (c: Buffer) => (stderr += c.toString()));
    child.on("error", (err) => resolve({ code: 127, stdout, stderr: err.message }));
    child.on("exit", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

function defaultExecInteractive(argv: readonly string[]): Promise<number> {
  return new Promise((resolve) => {
    const [cmd, ...rest] = argv;
    const child = spawnProcess(cmd!, rest, { stdio: "inherit" });
    child.on("error", () => resolve(127));
    child.on("exit", (code) => resolve(code ?? 1));
  });
}
