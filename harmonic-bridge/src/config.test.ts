import { test } from "node:test";
import assert from "node:assert/strict";
import { parse as parseYaml } from "yaml";
import {
  BUILTIN_RESOLVERS,
  ConfigError,
  parseAgentConfig,
  parseDaemonConfig,
} from "./config.js";

// ---------- daemon ----------

test("parseDaemonConfig: minimal valid config", () => {
  const cfg = parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /var/log/harmonic-bridge
`));
  assert.equal(cfg.listen.host, "127.0.0.1");
  assert.equal(cfg.listen.port, 8080);
  assert.equal(cfg.logDir, "/var/log/harmonic-bridge");
  assert.deepEqual({ ...cfg.secretResolvers }, { ...BUILTIN_RESOLVERS });
});

test("parseDaemonConfig: built-ins applied even when secret_resolvers omitted", () => {
  const cfg = parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /tmp
`));
  assert.equal(cfg.secretResolvers["file"], "cat {path}");
  assert.equal(cfg.secretResolvers["env"], "printenv {name}");
});

test("parseDaemonConfig: user resolvers merge with built-ins", () => {
  const cfg = parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /tmp
secret_resolvers:
  op: "op read {ref}"
  awssm: "aws secretsmanager get-secret-value --secret-id {ref}"
`));
  assert.equal(cfg.secretResolvers["file"], "cat {path}");          // built-in still there
  assert.equal(cfg.secretResolvers["op"], "op read {ref}");
  assert.equal(cfg.secretResolvers["awssm"], "aws secretsmanager get-secret-value --secret-id {ref}");
});

test("parseDaemonConfig: user resolver can override a built-in", () => {
  const cfg = parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /tmp
secret_resolvers:
  file: "sudo cat {path}"
`));
  assert.equal(cfg.secretResolvers["file"], "sudo cat {path}");
});

test("parseDaemonConfig: missing listen", () => {
  assert.throws(
    () => parseDaemonConfig(parseYaml("log_dir: /tmp\n")),
    (e: unknown) => e instanceof ConfigError && /listen/i.test(e.message),
  );
});

test("parseDaemonConfig: invalid listen port", () => {
  assert.throws(
    () => parseDaemonConfig(parseYaml("listen: localhost:99999\nlog_dir: /tmp\n")),
    (e: unknown) => e instanceof ConfigError && /port/i.test(e.message),
  );
});

test("parseDaemonConfig: listen without colon", () => {
  assert.throws(
    () => parseDaemonConfig(parseYaml("listen: 127.0.0.1\nlog_dir: /tmp\n")),
    (e: unknown) => e instanceof ConfigError && /host:port/.test(e.message),
  );
});

test("parseDaemonConfig: rejects non-object input", () => {
  assert.throws(() => parseDaemonConfig("just a string"), ConfigError);
  assert.throws(() => parseDaemonConfig(null), ConfigError);
  assert.throws(() => parseDaemonConfig([]), ConfigError);
});

test("parseDaemonConfig: secret_resolvers rejects invalid scheme name", () => {
  assert.throws(
    () => parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /tmp
secret_resolvers:
  "bad scheme!": "x"
`)),
    (e: unknown) => e instanceof ConfigError && /scheme/.test(e.message),
  );
});

// ---------- agent ----------

const validAgent = `
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: op://Personal/harmonic-dev/token
webhook_secret: op://Personal/harmonic-dev/webhook
working_dir: /home/agent/code/Harmonic
wake_command: |
  claude -p --append-system-prompt @system-prompt.md
`;

test("parseAgentConfig: minimal valid config", () => {
  const cfg = parseAgentConfig(parseYaml(validAgent));
  assert.equal(cfg.harmonicMcpEndpoint, "https://app.harmonic.example/mcp");
  assert.equal(cfg.harmonicToken, "op://Personal/harmonic-dev/token");
  assert.equal(cfg.webhookSecret, "op://Personal/harmonic-dev/webhook");
  assert.equal(cfg.workingDir, "/home/agent/code/Harmonic");
  assert.match(cfg.wakeCommand, /^claude -p/);
  assert.equal(cfg.events, undefined);
  assert.equal(cfg.timeoutSeconds, undefined);
  assert.equal(cfg.env, undefined);
});

test("parseAgentConfig: optional fields parse cleanly", () => {
  const cfg = parseAgentConfig(parseYaml(validAgent + `
events:
  - notifications.delivered
  - reminders.delivered
timeout_seconds: 900
env:
  ANTHROPIC_API_KEY: op://Personal/anthropic-key
  EXTRA: literal_value
`));
  assert.deepEqual([...cfg.events ?? []], ["notifications.delivered", "reminders.delivered"]);
  assert.equal(cfg.timeoutSeconds, 900);
  assert.deepEqual({ ...cfg.env }, {
    ANTHROPIC_API_KEY: "op://Personal/anthropic-key",
    EXTRA: "literal_value",
  });
});

test("parseAgentConfig: missing required field", () => {
  // missing wake_command
  assert.throws(
    () => parseAgentConfig(parseYaml(`
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: x
webhook_secret: y
working_dir: /tmp
`)),
    (e: unknown) => e instanceof ConfigError && /wake_command/.test(e.message),
  );
});

test("parseAgentConfig: invalid URL", () => {
  assert.throws(
    () => parseAgentConfig(parseYaml(`
harmonic_mcp_endpoint: not a url
harmonic_token: x
webhook_secret: y
working_dir: /tmp
wake_command: x
`)),
    (e: unknown) => e instanceof ConfigError && /harmonic_mcp_endpoint/.test(e.message),
  );
});

test("parseAgentConfig: non-positive timeout_seconds", () => {
  assert.throws(
    () => parseAgentConfig(parseYaml(validAgent + "timeout_seconds: 0\n")),
    (e: unknown) => e instanceof ConfigError && /timeout_seconds/.test(e.message),
  );
});

test("parseAgentConfig: events must be strings", () => {
  assert.throws(
    () => parseAgentConfig(parseYaml(validAgent + "events:\n  - 1\n  - 2\n")),
    (e: unknown) => e instanceof ConfigError && /events/.test(e.message),
  );
});

test("parseAgentConfig: env must be string-to-string map", () => {
  assert.throws(
    () => parseAgentConfig(parseYaml(validAgent + "env:\n  KEY: 42\n")),
    (e: unknown) => e instanceof ConfigError && /env\["KEY"\]/.test(e.message),
  );
});

// ---------- after_add ----------

test("parseDaemonConfig: after_add defaults to empty list when absent", () => {
  const cfg = parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /var/log/harmonic-bridge
`));
  assert.deepEqual(cfg.afterAdd, []);
});

test("parseDaemonConfig: after_add accepts built_in and command forms", () => {
  const cfg = parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /var/log/harmonic-bridge
after_add:
  - built_in: claude-code-per-agent-mcp-config
  - command: claude mcp add harmonic ...
`));
  assert.equal(cfg.afterAdd.length, 2);
  assert.deepEqual(cfg.afterAdd[0], { kind: "built_in", name: "claude-code-per-agent-mcp-config" });
  assert.deepEqual(cfg.afterAdd[1], { kind: "command", command: "claude mcp add harmonic ..." });
});

test("parseDaemonConfig: after_add entry must specify exactly one form", () => {
  assert.throws(
    () => parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /var/log/harmonic-bridge
after_add:
  - {}
`)),
    (e: unknown) => e instanceof ConfigError && /built_in or command/.test(e.message),
  );

  assert.throws(
    () => parseDaemonConfig(parseYaml(`
listen: 127.0.0.1:8080
log_dir: /var/log/harmonic-bridge
after_add:
  - built_in: foo
    command: bar
`)),
    (e: unknown) => e instanceof ConfigError && /not both/.test(e.message),
  );
});

test("parseAgentConfig: after_add absent means undefined (inherit daemon defaults)", () => {
  const cfg = parseAgentConfig(parseYaml(validAgent));
  assert.equal(cfg.afterAdd, undefined);
});

test("parseAgentConfig: after_add present (even empty) is preserved as override", () => {
  const empty = parseAgentConfig(parseYaml(validAgent + "after_add: []\n"));
  assert.deepEqual(empty.afterAdd, []);
  assert.notEqual(empty.afterAdd, undefined);

  const populated = parseAgentConfig(parseYaml(validAgent + `after_add:
  - command: my-script.sh
`));
  assert.deepEqual(populated.afterAdd, [{ kind: "command", command: "my-script.sh" }]);
});
