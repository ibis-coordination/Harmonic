import { test } from "node:test";
import assert from "node:assert/strict";
import type { AdminConfig } from "./config.js";
import { runProdStatus } from "./status.js";

const HEALTHY_BODY = JSON.stringify({ status: "ok", checks: { database: true, redis: true } });
const UNHEALTHY_BODY = JSON.stringify({ status: "unhealthy", checks: { database: true, redis: false } });

const METRICS_BODY = [
  'sidekiq_jobs_waiting_count{queue="default"} 4',
  "sidekiq_jobs_retry_count 1",
  "sidekiq_jobs_dead_count 0",
  "sidekiq_active_workers_count 2",
].join("\n");

const SENTRY_ISSUES = [
  {
    id: "1",
    shortId: "HARMONIC-7",
    title: "Timeout::Error in webhooks",
    count: "12",
    userCount: 2,
    level: "error",
    lastSeen: "2026-07-31T10:00:00Z",
  },
];

function makeConfig(values: Record<string, string>): AdminConfig {
  return {
    values: values as AdminConfig["values"],
    sources: {},
    path: "/tmp/none",
    fileExists: true,
  };
}

type Route = { status: number; body: string };

function fakeFetch(routes: Record<string, Route>): typeof fetch {
  return (async (input: string | URL | Request) => {
    const url = String(input);
    const path = url.split("?")[0] ?? url;
    const route = routes[path];
    if (!route) return new Response("not found", { status: 404 });
    return new Response(route.body, { status: route.status });
  }) as typeof fetch;
}

const FULL_CONFIG = {
  HARMONIC_PROD_URL: "https://prod.example",
  HARMONIC_METRICS_TOKEN: "metrics-tok",
  SENTRY_API_TOKEN: "sentry-tok",
  SENTRY_ORG: "ibis",
  SENTRY_PROJECT: "harmonic",
  SENTRY_BASE_URL: "https://sentry.example",
};

const FULL_ROUTES: Record<string, Route> = {
  "https://prod.example/healthcheck": { status: 200, body: HEALTHY_BODY },
  "https://prod.example/metrics": { status: 200, body: METRICS_BODY },
  "https://sentry.example/api/0/projects/ibis/harmonic/issues/": {
    status: 200,
    body: JSON.stringify(SENTRY_ISSUES),
  },
};

test("runProdStatus: all sources configured and healthy", async () => {
  const result = await runProdStatus(makeConfig(FULL_CONFIG), { fetchImpl: fakeFetch(FULL_ROUTES) });
  assert.equal(result.exitCode, 0);
  const text = result.sections.map((s) => `${s.title}\n${s.lines.join("\n")}`).join("\n\n");
  assert.match(text, /database: ok/);
  assert.match(text, /redis: ok/);
  assert.match(text, /waiting: 4/);
  assert.match(text, /dead: 0/);
  assert.match(text, /HARMONIC-7/);
  assert.match(text, /12 events/);
});

test("runProdStatus: unhealthy healthcheck sets exit code 1 and names the failing check", async () => {
  const routes = {
    ...FULL_ROUTES,
    "https://prod.example/healthcheck": { status: 503, body: UNHEALTHY_BODY },
  };
  const result = await runProdStatus(makeConfig(FULL_CONFIG), { fetchImpl: fakeFetch(routes) });
  assert.equal(result.exitCode, 1);
  const availability = result.sections.find((s) => s.title.toLowerCase().includes("availability"));
  assert.ok(availability);
  assert.equal(availability.state, "down");
  assert.match(availability.lines.join("\n"), /redis: FAILING/);
});

test("runProdStatus: unreachable host reports down, other sections still render", async () => {
  const failFetch = (async (input: string | URL | Request) => {
    const url = String(input);
    if (url.startsWith("https://prod.example")) throw new Error("getaddrinfo ENOTFOUND prod.example");
    const path = url.split("?")[0] ?? url;
    const route = FULL_ROUTES[path];
    if (!route) return new Response("not found", { status: 404 });
    return new Response(route.body, { status: route.status });
  }) as typeof fetch;
  const result = await runProdStatus(makeConfig(FULL_CONFIG), { fetchImpl: failFetch });
  assert.equal(result.exitCode, 1);
  const text = result.sections.map((s) => s.lines.join("\n")).join("\n");
  assert.match(text, /unreachable/i);
  assert.match(text, /HARMONIC-7/);
});

test("runProdStatus: missing metrics token degrades to a no-access line", async () => {
  const { HARMONIC_METRICS_TOKEN: _omitted, ...withoutMetricsToken } = FULL_CONFIG;
  const result = await runProdStatus(makeConfig(withoutMetricsToken), { fetchImpl: fakeFetch(FULL_ROUTES) });
  assert.equal(result.exitCode, 0);
  const jobs = result.sections.find((s) => s.title.toLowerCase().includes("jobs"));
  assert.ok(jobs);
  assert.equal(jobs.state, "no-access");
  assert.match(jobs.lines.join("\n"), /HARMONIC_METRICS_TOKEN/);
});

test("runProdStatus: missing Sentry credentials degrade to a no-access line naming the missing keys", async () => {
  const { SENTRY_API_TOKEN: _a, SENTRY_ORG: _b, ...rest } = FULL_CONFIG;
  const result = await runProdStatus(makeConfig(rest), { fetchImpl: fakeFetch(FULL_ROUTES) });
  const errors = result.sections.find((s) => s.title.toLowerCase().includes("error"));
  assert.ok(errors);
  assert.equal(errors.state, "no-access");
  assert.match(errors.lines.join("\n"), /SENTRY_API_TOKEN/);
  assert.match(errors.lines.join("\n"), /SENTRY_ORG/);
});

test("runProdStatus: metrics endpoint 503 (token unset server-side) explains rather than crashes", async () => {
  const routes = {
    ...FULL_ROUTES,
    "https://prod.example/metrics": { status: 503, body: "Metrics unavailable" },
  };
  const result = await runProdStatus(makeConfig(FULL_CONFIG), { fetchImpl: fakeFetch(routes) });
  assert.equal(result.exitCode, 0);
  const jobs = result.sections.find((s) => s.title.toLowerCase().includes("jobs"));
  assert.ok(jobs);
  assert.equal(jobs.state, "no-access");
  assert.match(jobs.lines.join("\n"), /503/);
});

test("runProdStatus: dead jobs present flips the jobs section to warn", async () => {
  const routes = {
    ...FULL_ROUTES,
    "https://prod.example/metrics": {
      status: 200,
      body: 'sidekiq_jobs_waiting_count{queue="default"} 0\nsidekiq_jobs_dead_count 9\n',
    },
  };
  const result = await runProdStatus(makeConfig(FULL_CONFIG), { fetchImpl: fakeFetch(routes) });
  const jobs = result.sections.find((s) => s.title.toLowerCase().includes("jobs"));
  assert.equal(jobs?.state, "warn");
});

test("runProdStatus: no unresolved issues reads as ok", async () => {
  const routes = {
    ...FULL_ROUTES,
    "https://sentry.example/api/0/projects/ibis/harmonic/issues/": { status: 200, body: "[]" },
  };
  const result = await runProdStatus(makeConfig(FULL_CONFIG), { fetchImpl: fakeFetch(routes) });
  const errors = result.sections.find((s) => s.title.toLowerCase().includes("error"));
  assert.equal(errors?.state, "ok");
  assert.match(errors?.lines.join("\n") ?? "", /no unresolved issues/i);
});
