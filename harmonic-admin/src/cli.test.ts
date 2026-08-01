import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { runCommand } from "./cli.js";

function collect(stream: PassThrough): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    stream.on("data", (c: Buffer) => chunks.push(c));
    stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    stream.on("error", reject);
  });
}

interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}

async function run(
  args: string[],
  opts: { configPath?: string; env?: Record<string, string>; fetchImpl?: typeof fetch } = {},
): Promise<RunResult> {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const stdoutPromise = collect(stdout);
  const stderrPromise = collect(stderr);
  const code = await runCommand(args, {
    configPath: opts.configPath ?? "/nonexistent/harmonic-admin/env",
    env: opts.env ?? {},
    fetchImpl: opts.fetchImpl,
    stdout,
    stderr,
  });
  stdout.end();
  stderr.end();
  return { code, stdout: await stdoutPromise, stderr: await stderrPromise };
}

async function withTempConfig<T>(contents: string, fn: (configPath: string) => Promise<T>): Promise<T> {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-admin-cli-"));
  try {
    const configPath = path.join(dir, "env");
    writeFileSync(configPath, contents);
    return await fn(configPath);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const SENTRY_CONFIG = [
  "SENTRY_API_TOKEN=tok-secret-value",
  "SENTRY_ORG=ibis",
  "SENTRY_PROJECT=harmonic",
  "SENTRY_BASE_URL=https://sentry.example",
  "HARMONIC_PROD_URL=https://prod.example",
].join("\n");

const ISSUE = {
  id: "123456",
  shortId: "HARMONIC-42",
  title: "NoMethodError in notes",
  count: "17",
  userCount: 3,
  level: "error",
  lastSeen: "2026-07-31T09:08:07Z",
  permalink: "https://sentry.example/organizations/ibis/issues/123456/",
};

function fakeFetch(routes: Record<string, { status: number; body: string }>): typeof fetch {
  return (async (input: string | URL | Request) => {
    const url = String(input);
    const urlPath = url.split("?")[0] ?? url;
    const route = routes[urlPath];
    if (!route) return new Response("not found", { status: 404 });
    return new Response(route.body, { status: route.status });
  }) as typeof fetch;
}

test("help: prints usage with execution locus and mutation note", async () => {
  const result = await run(["help"]);
  assert.equal(result.code, 0);
  assert.match(result.stdout, /Usage: harmonic-admin/);
  assert.match(result.stdout, /prod status/);
  assert.match(result.stdout, /doctor/);
  assert.match(result.stdout, /Read-only/);
  assert.match(result.stdout, /HTTPS/);
});

test("no args: prints usage", async () => {
  const result = await run([]);
  assert.equal(result.code, 0);
  assert.match(result.stdout, /Usage: harmonic-admin/);
});

test("unknown command: exit 64 with message on stderr", async () => {
  const result = await run(["bogus"]);
  assert.equal(result.code, 64);
  assert.match(result.stderr, /unknown command "bogus"/);
});

test("doctor: reports set/not-set per key without printing secret values", async () => {
  await withTempConfig(SENTRY_CONFIG, async (configPath) => {
    const result = await run(["doctor"], { configPath });
    assert.equal(result.code, 0);
    assert.match(result.stdout, /SENTRY_API_TOKEN\s+set \(file\)/);
    assert.match(result.stdout, /HARMONIC_METRICS_TOKEN\s+not set/);
    assert.ok(!result.stdout.includes("tok-secret-value"));
    assert.match(result.stdout, /SENTRY_ORG\s+ibis \(file\)/);
    assert.match(result.stdout, /HARMONIC_PROD_URL\s+https:\/\/prod\.example \(file\)/);
    assert.match(result.stdout, new RegExp(configPath.replace(/[/\\]/g, "[/\\\\]")));
  });
});

test("doctor: notes when the config file does not exist", async () => {
  const result = await run(["doctor"]);
  assert.equal(result.code, 0);
  assert.match(result.stdout, /does not exist/);
});

test("prod status: renders sections and exits 0 when healthy", async () => {
  await withTempConfig(SENTRY_CONFIG, async (configPath) => {
    const routes = {
      "https://prod.example/healthcheck": {
        status: 200,
        body: JSON.stringify({ status: "ok", checks: { database: true, redis: true } }),
      },
      "https://sentry.example/api/0/projects/ibis/harmonic/issues/": {
        status: 200,
        body: JSON.stringify([ISSUE]),
      },
    };
    const result = await run(["prod", "status"], { configPath, fetchImpl: fakeFetch(routes) });
    assert.equal(result.code, 0);
    assert.match(result.stdout, /Availability/);
    assert.match(result.stdout, /database: ok/);
    assert.match(result.stdout, /no access to metrics/);
    assert.match(result.stdout, /HARMONIC-42/);
  });
});

test("prod sentry issues: lists unresolved issues", async () => {
  await withTempConfig(SENTRY_CONFIG, async (configPath) => {
    const routes = {
      "https://sentry.example/api/0/projects/ibis/harmonic/issues/": {
        status: 200,
        body: JSON.stringify([ISSUE]),
      },
    };
    const result = await run(["prod", "sentry", "issues"], { configPath, fetchImpl: fakeFetch(routes) });
    assert.equal(result.code, 0);
    assert.match(result.stdout, /HARMONIC-42/);
    assert.match(result.stdout, /17 events/);
  });
});

test("prod sentry issues: missing credentials explains what to set and exits 1", async () => {
  const result = await run(["prod", "sentry", "issues"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /SENTRY_API_TOKEN/);
});

test("prod sentry show: renders issue detail with latest event tags", async () => {
  await withTempConfig(SENTRY_CONFIG, async (configPath) => {
    const routes = {
      "https://sentry.example/api/0/issues/123456/": { status: 200, body: JSON.stringify(ISSUE) },
      "https://sentry.example/api/0/issues/123456/events/latest/": {
        status: 200,
        body: JSON.stringify({
          dateCreated: "2026-07-31T09:08:07Z",
          message: "undefined method",
          tags: [{ key: "release", value: "1.63.0" }],
        }),
      },
    };
    const result = await run(["prod", "sentry", "show", "123456"], { configPath, fetchImpl: fakeFetch(routes) });
    assert.equal(result.code, 0);
    assert.match(result.stdout, /HARMONIC-42/);
    assert.match(result.stdout, /release: 1\.63\.0/);
  });
});

test("prod sentry show: missing id is a usage error", async () => {
  await withTempConfig(SENTRY_CONFIG, async (configPath) => {
    const result = await run(["prod", "sentry", "show"], { configPath });
    assert.equal(result.code, 64);
    assert.match(result.stderr, /requires an issue id/);
  });
});
