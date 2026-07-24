import { test } from "node:test";
import assert from "node:assert/strict";
import { Writable } from "node:stream";
import { runSetupSprite, type Exec, type ExecInteractive } from "./setup-sprite.js";

function collect(): { stream: Writable; text: () => string } {
  const chunks: string[] = [];
  return {
    stream: new Writable({
      write(chunk: Buffer, _enc, cb) {
        chunks.push(chunk.toString());
        cb();
      },
    }),
    text: () => chunks.join(""),
  };
}

interface FakeCall {
  readonly argv: readonly string[];
  readonly script: string | undefined;
}

/**
 * Fake `sprite` CLI. Routes by argv shape; in-sprite shell scripts (the
 * `sh -c` payload) route by content. Overrides let tests fail specific
 * steps or change probe answers.
 */
function makeFakeExec(overrides?: {
  listFails?: boolean;
  spriteExists?: boolean;
  claudeAuthed?: boolean;
  addFails?: boolean;
}): { exec: Exec; calls: FakeCall[] } {
  const calls: FakeCall[] = [];
  const exec: Exec = async (argv) => {
    const script = argv.includes("sh") ? argv[argv.length - 1] : undefined;
    calls.push({ argv, script });
    const joined = argv.join(" ");

    if (joined === "sprite list") {
      if (overrides?.listFails) return { code: 1, stdout: "", stderr: "Error: no organizations configured" };
      return { code: 0, stdout: overrides?.spriteExists ? "my-agent\nother\n" : "other\n", stderr: "" };
    }
    if (joined.startsWith("sprite create")) return { code: 0, stdout: "", stderr: "" };
    if (joined.startsWith("sprite url update")) return { code: 0, stdout: "", stderr: "" };
    if (joined.startsWith("sprite url")) {
      return { code: 0, stdout: "URL: https://my-agent-abc123.sprites.app\nAuth: sprite\n", stderr: "" };
    }
    if (script !== undefined) {
      if (script.includes("npm install")) return { code: 0, stdout: "added 1 package\n", stderr: "" };
      if (script.includes("harmonic-bridge init")) return { code: 0, stdout: "", stderr: "" };
      if (script.includes("base64 -d")) return { code: 0, stdout: "", stderr: "" };
      if (script.includes("test -d /home/sprite/.claude")) {
        return { code: overrides?.claudeAuthed ? 0 : 1, stdout: "", stderr: "" };
      }
      if (script.includes("services list")) return { code: 0, stdout: "[]", stderr: "" };
      if (script.includes("services create") || script.includes("services restart")) {
        return { code: 0, stdout: "", stderr: "" };
      }
      if (script.includes("harmonic-bridge add")) {
        if (overrides?.addFails) return { code: 1, stdout: "", stderr: "setup URL is invalid or expired (404)" };
        return { code: 0, stdout: 'Agent "biz" added.\n', stderr: "" };
      }
    }
    return { code: 0, stdout: "", stderr: "" };
  };
  return { exec, calls };
}

function makeFakeInteractive(): { execInteractive: ExecInteractive; calls: string[][] } {
  const calls: string[][] = [];
  return {
    execInteractive: async (argv) => {
      calls.push([...argv]);
      return 0;
    },
    calls,
  };
}

function makeFakeFetch(status = 405): { fetch: typeof fetch; urls: string[] } {
  const urls: string[] = [];
  const fake = (async (input: RequestInfo | URL) => {
    urls.push(String(input));
    return new Response(null, { status });
  }) as typeof fetch;
  return { fetch: fake, urls };
}

const FROM_URL = "https://sandbox.harmonic.example/bridge-setups/abc123";

async function run(
  args: string[],
  fakes?: {
    exec?: Exec;
    execInteractive?: ExecInteractive;
    fetch?: typeof fetch;
  },
): Promise<{ code: number; out: string; err: string; }> {
  const out = collect();
  const err = collect();
  const defaults = makeFakeExec();
  const code = await runSetupSprite(args, {
    exec: fakes?.exec ?? defaults.exec,
    execInteractive: fakes?.execInteractive ?? makeFakeInteractive().execInteractive,
    fetch: fakes?.fetch ?? makeFakeFetch().fetch,
    stdout: out.stream,
    stderr: err.stream,
  });
  return { code, out: out.text(), err: err.text() };
}

function configWrittenBy(calls: FakeCall[]): string {
  const call = calls.find((c) => c.script?.includes("base64 -d") && c.script?.includes("config.yml"));
  assert.ok(call?.script, "expected a config.yml write via base64");
  const b64 = call.script.match(/echo '([A-Za-z0-9+/=]+)'/)?.[1];
  assert.ok(b64, "expected base64 payload in config write");
  return Buffer.from(b64, "base64").toString("utf8");
}

test("setup-sprite: requires --from", async () => {
  const r = await run(["--sprite-name", "my-agent"]);
  assert.equal(r.code, 64);
  assert.match(r.err, /--from/);
});

test("setup-sprite: rejects unknown --harness values and names the supported ones", async () => {
  const r = await run(["--from", FROM_URL, "--harness", "totally-fake"]);
  assert.equal(r.code, 64);
  assert.match(r.err, /unknown harness "totally-fake"/);
  assert.match(r.err, /claude-code/);
});

test("setup-sprite: without --harness, no harness assumptions are made", async () => {
  const fake = makeFakeExec();
  const interactive = makeFakeInteractive();
  const probe = makeFakeFetch();
  const r = await run(["--from", FROM_URL, "--sprite-name", "my-agent"], {
    exec: fake.exec,
    execInteractive: interactive.execInteractive,
    fetch: probe.fetch,
  });
  assert.equal(r.code, 0, r.err);

  const config = configWrittenBy(fake.calls);
  assert.match(config, /hold_awake_during_wake: true/);
  assert.match(config, /public_url: "https:\/\/my-agent-abc123\.sprites\.app"/);
  assert.doesNotMatch(config, /claude/, "config must not reference any harness without --harness");

  assert.equal(interactive.calls.length, 0, "no interactive harness auth without --harness");
  const allScripts = fake.calls.map((c) => c.script ?? "").join("\n");
  assert.doesNotMatch(allScripts, /claude login/);
  assert.match(r.out, /wake_command/, "must tell the user to wire a harness manually");
});

test("setup-sprite: --harness claude-code opts into the claude after_add steps and login flow", async () => {
  const fake = makeFakeExec();
  const interactive = makeFakeInteractive();
  const r = await run(["--from", FROM_URL, "--sprite-name", "my-agent", "--harness", "claude-code"], {
    exec: fake.exec,
    execInteractive: interactive.execInteractive,
  });
  assert.equal(r.code, 0, r.err);

  const config = configWrittenBy(fake.calls);
  assert.match(config, /claude-code-per-agent-mcp-config/);
  assert.match(config, /claude-code-harness/);

  assert.equal(interactive.calls.length, 1, "claude login handoff expected when not authed");
  assert.ok(interactive.calls[0]!.join(" ").includes("claude login"), `got: ${interactive.calls[0]!.join(" ")}`);
});

test("setup-sprite: skips the login handoff when claude is already authed in the sprite", async () => {
  const fake = makeFakeExec({ claudeAuthed: true });
  const interactive = makeFakeInteractive();
  const r = await run(["--from", FROM_URL, "--sprite-name", "my-agent", "--harness", "claude-code"], {
    exec: fake.exec,
    execInteractive: interactive.execInteractive,
  });
  assert.equal(r.code, 0, r.err);
  assert.equal(interactive.calls.length, 0);
});

test("setup-sprite: reuses an existing sprite instead of creating", async () => {
  const fake = makeFakeExec({ spriteExists: true });
  const r = await run(["--from", FROM_URL, "--sprite-name", "my-agent"], { exec: fake.exec });
  assert.equal(r.code, 0, r.err);
  assert.ok(!fake.calls.some((c) => c.argv.join(" ").startsWith("sprite create")), "must not create existing sprite");
});

test("setup-sprite: fails with a login hint when the sprite CLI is unusable", async () => {
  const fake = makeFakeExec({ listFails: true });
  const r = await run(["--from", FROM_URL, "--sprite-name", "my-agent"], { exec: fake.exec });
  assert.equal(r.code, 1);
  assert.match(r.err, /sprite login|sprite org auth/);
});

test("setup-sprite: add failure stops the run and explains the single-use URL", async () => {
  const fake = makeFakeExec({ addFails: true });
  const probe = makeFakeFetch();
  const r = await run(["--from", FROM_URL, "--sprite-name", "my-agent"], { exec: fake.exec, fetch: probe.fetch });
  assert.equal(r.code, 1);
  assert.match(r.err, /fresh URL|Connect harmonic-bridge/);
  assert.equal(probe.urls.length, 0, "no smoke probe after failed add");
});

test("setup-sprite: never redeems the --from URL from the laptop", async () => {
  const fake = makeFakeExec();
  const probe = makeFakeFetch();
  const r = await run(["--from", FROM_URL, "--sprite-name", "my-agent"], { exec: fake.exec, fetch: probe.fetch });
  assert.equal(r.code, 0, r.err);
  assert.ok(!probe.urls.some((u) => u.includes("bridge-setups")), "the single-use URL must only be redeemed in-sprite");
  assert.equal(probe.urls.length, 1);
  assert.match(probe.urls[0]!, /https:\/\/my-agent-abc123\.sprites\.app\/webhook\/probe/);
});

test("setup-sprite: orders service start and public URL before add", async () => {
  const fake = makeFakeExec();
  const r = await run(["--from", FROM_URL, "--sprite-name", "my-agent"], { exec: fake.exec });
  assert.equal(r.code, 0, r.err);
  const sequence = fake.calls.map((c) => c.script ?? c.argv.join(" "));
  const serviceIdx = sequence.findIndex((s) => s.includes("services create"));
  const publicIdx = sequence.findIndex((s) => s.includes("url update"));
  const addIdx = sequence.findIndex((s) => s.includes("harmonic-bridge add"));
  assert.ok(serviceIdx >= 0 && publicIdx >= 0 && addIdx >= 0, `missing steps in: ${sequence.join(" | ")}`);
  assert.ok(serviceIdx < addIdx, "daemon must be running before add (Harmonic verifies synchronously)");
  assert.ok(publicIdx < addIdx, "URL must be public before add");
});
