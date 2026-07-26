import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Writable } from "node:stream";
import { parse as parseYaml } from "yaml";
import { runStep, runSteps, effectiveAfterAdd, type Step, type StepContext } from "./steps.js";

function makeContext(agentDir: string): StepContext {
  return {
    agentHandle: "alice",
    agentDir,
    mcpEndpoint: "https://app.harmonic.example/mcp",
    token: "tok_test_secret",
  };
}

function makeTmpAgentDir(): { dir: string; cleanup: () => void } {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-step-"));
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

function collectStream(): { stream: Writable; output: () => string } {
  const chunks: Buffer[] = [];
  const stream = new Writable({
    write(chunk, _enc, cb) {
      chunks.push(Buffer.from(chunk));
      cb();
    },
  });
  return { stream, output: () => Buffer.concat(chunks).toString("utf8") };
}

// ---------- runStep: built-in ----------

test("runStep built_in: claude-code-per-agent-mcp-config writes the expected file", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    const result = await runStep(
      { kind: "built_in", name: "claude-code-per-agent-mcp-config" },
      makeContext(dir),
    );
    assert.equal(result.ok, true);
    const mcpConfigPath = path.join(dir, "mcp-config.json");
    assert.ok(existsSync(mcpConfigPath));
    const config = JSON.parse(readFileSync(mcpConfigPath, "utf8"));
    assert.ok(config.mcpServers["harmonic-alice"]);
    assert.equal(config.mcpServers["harmonic-alice"].url, "https://app.harmonic.example/mcp");
    assert.equal(
      config.mcpServers["harmonic-alice"].headers.Authorization,
      "Bearer ${HARMONIC_BRIDGE_TOKEN}",
    );
  } finally {
    cleanup();
  }
});

test("runStep built_in: goose-per-agent-mcp-config writes the relocated config root", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    const result = await runStep({ kind: "built_in", name: "goose-per-agent-mcp-config" }, makeContext(dir));
    assert.equal(result.ok, true);
    const configPath = path.join(dir, "home", ".config", "goose", "config.yaml");
    assert.ok(existsSync(configPath));
    const config = parseYaml(readFileSync(configPath, "utf8")) as Record<string, any>;
    assert.equal(config["extensions"]["harmonic-alice"]["uri"], "https://app.harmonic.example/mcp");
    // The step context carries a resolved plaintext token; it must not land here.
    assert.doesNotMatch(readFileSync(configPath, "utf8"), /tok_test_secret/);
  } finally {
    cleanup();
  }
});

test("runStep built_in: goose-harness configures the agent for goose", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    writeFileSync(
      path.join(dir, "harmonic-bridge.yml"),
      'wake_command: |\n  echo "wake_command not configured" >&2\n  exit 1\n',
    );
    const result = await runStep({ kind: "built_in", name: "goose-harness" }, makeContext(dir));
    assert.equal(result.ok, true);

    const yml = parseYaml(readFileSync(path.join(dir, "harmonic-bridge.yml"), "utf8")) as Record<string, unknown>;
    assert.match(yml["wake_command"] as string, /goose run/);
    // The handle reaches the harness, not just the config writer.
    assert.match(readFileSync(path.join(dir, "system-prompt.md"), "utf8"), /harmonic-alice/);
  } finally {
    cleanup();
  }
});

test("runStep built_in: unknown name returns an error result", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    const result = await runStep(
      { kind: "built_in", name: "no-such-step" },
      makeContext(dir),
    );
    assert.equal(result.ok, false);
    assert.match((result as { error: string }).error, /unknown built-in step/);
  } finally {
    cleanup();
  }
});

// ---------- runStep: command ----------

test("runStep command: success returns ok and runs with HARMONIC_BRIDGE_* env set", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    const outFile = path.join(dir, "out.txt");
    const result = await runStep(
      {
        kind: "command",
        command: `printf '%s|%s|%s|%s' "$HARMONIC_BRIDGE_AGENT_NAME" "$HARMONIC_BRIDGE_AGENT_DIR" "$HARMONIC_BRIDGE_MCP_ENDPOINT" "$HARMONIC_BRIDGE_TOKEN" > ${outFile}`,
      },
      makeContext(dir),
    );
    assert.equal(result.ok, true);
    const written = readFileSync(outFile, "utf8");
    assert.equal(written, `alice|${dir}|https://app.harmonic.example/mcp|tok_test_secret`);
  } finally {
    cleanup();
  }
});

test("runStep command: cwd is the agent dir", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    const outFile = path.join(dir, "pwd.txt");
    const result = await runStep(
      { kind: "command", command: `pwd > ${outFile}` },
      makeContext(dir),
    );
    assert.equal(result.ok, true);
    const pwd = readFileSync(outFile, "utf8").trim();
    // macOS resolves /tmp through /private/tmp, so the shell's $PWD may be a
    // different string than `dir` even though both point at the same inode.
    // Compare via realpath to normalize.
    assert.equal(realpathSync(pwd), realpathSync(dir));
  } finally {
    cleanup();
  }
});

test("runStep command: non-zero exit returns ok=false with detail", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    const result = await runStep(
      { kind: "command", command: "exit 3" },
      makeContext(dir),
    );
    assert.equal(result.ok, false);
    assert.match((result as { error: string }).error, /exit code 3/);
  } finally {
    cleanup();
  }
});

test("runStep command: timeout kills the process and returns ok=false", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    const result = await runStep(
      { kind: "command", command: "sleep 5" },
      makeContext(dir),
      { timeoutSeconds: 0.2 },
    );
    assert.equal(result.ok, false);
    assert.match((result as { error: string }).error, /timed out/);
  } finally {
    cleanup();
  }
});

test("runStep command: stdout is captured into the provided stream", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  const { stream, output } = collectStream();
  try {
    const result = await runStep(
      { kind: "command", command: "printf hello-from-step" },
      makeContext(dir),
      { stdout: stream },
    );
    assert.equal(result.ok, true);
    // Allow a tick for piped writes to flush.
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(output(), "hello-from-step");
  } finally {
    cleanup();
  }
});

// ---------- runSteps: list semantics ----------

test("runSteps: runs sequentially, continues past a failure, fires onResult per step", async () => {
  const { dir, cleanup } = makeTmpAgentDir();
  try {
    const seq: string[] = [];
    const steps: Step[] = [
      { kind: "command", command: `echo first > ${path.join(dir, "first.txt")}` },
      { kind: "command", command: "exit 1" },
      { kind: "command", command: `echo third > ${path.join(dir, "third.txt")}` },
    ];
    const results = await runSteps(steps, makeContext(dir), {
      onResult: (step, result) => {
        const tag = step.kind === "command" ? step.command.split(" ")[0] : step.name;
        seq.push(`${tag}:${result.ok ? "ok" : "fail"}`);
      },
    });
    assert.equal(results.length, 3);
    assert.equal(results[0]!.ok, true);
    assert.equal(results[1]!.ok, false);
    assert.equal(results[2]!.ok, true);
    assert.deepEqual(seq, ["echo:ok", "exit:fail", "echo:ok"]);
    // Third step ran even after the second failed.
    assert.ok(existsSync(path.join(dir, "third.txt")));
  } finally {
    cleanup();
  }
});

// ---------- effectiveAfterAdd: override semantics ----------

test("effectiveAfterAdd: undefined agent override inherits daemon defaults", () => {
  const daemonSteps: Step[] = [{ kind: "built_in", name: "claude-code-per-agent-mcp-config" }];
  const effective = effectiveAfterAdd(undefined, daemonSteps);
  assert.equal(effective, daemonSteps);
});

test("effectiveAfterAdd: explicit empty agent list overrides daemon to none", () => {
  const daemonSteps: Step[] = [{ kind: "built_in", name: "claude-code-per-agent-mcp-config" }];
  const effective = effectiveAfterAdd([], daemonSteps);
  assert.deepEqual(effective, []);
});

test("effectiveAfterAdd: non-empty agent list replaces daemon defaults wholesale", () => {
  const daemonSteps: Step[] = [{ kind: "built_in", name: "claude-code-per-agent-mcp-config" }];
  const agentSteps: Step[] = [{ kind: "command", command: "codex mcp add ..." }];
  const effective = effectiveAfterAdd(agentSteps, daemonSteps);
  assert.equal(effective, agentSteps);
});
