// `prod status` — one command answering "how's prod doing?" from a laptop,
// no SSH. Acts over HTTPS against the prod instance (/healthcheck, /metrics)
// and the Sentry API. Read-only. Each source degrades independently: a
// missing credential yields a "no access" section, never a crash.

import type { AdminConfig } from "./config.js";
import { parsePrometheusText, summarizeSidekiq } from "./prom.js";
import { SentryClient } from "./sentry.js";

export type SectionState = "ok" | "warn" | "down" | "no-access";

export interface StatusSection {
  readonly title: string;
  readonly state: SectionState;
  readonly lines: readonly string[];
}

export interface ProdStatusResult {
  readonly sections: readonly StatusSection[];
  /** 0 when the app is up (regardless of missing optional sources), 1 when down/unreachable. */
  readonly exitCode: number;
}

export interface RunProdStatusOpts {
  readonly fetchImpl?: typeof fetch;
}

export async function runProdStatus(config: AdminConfig, opts: RunProdStatusOpts = {}): Promise<ProdStatusResult> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const prodUrl = (config.values.HARMONIC_PROD_URL ?? "https://www.harmonic.social").replace(/\/$/, "");

  const [availability, jobs, errors] = await Promise.all([
    checkAvailability(prodUrl, fetchImpl),
    checkJobs(prodUrl, config, fetchImpl),
    checkErrors(config, fetchImpl),
  ]);

  return {
    sections: [availability, jobs, errors],
    exitCode: availability.state === "down" ? 1 : 0,
  };
}

async function checkAvailability(prodUrl: string, fetchImpl: typeof fetch): Promise<StatusSection> {
  const title = `Availability (${prodUrl}/healthcheck)`;
  let response: Response;
  try {
    response = await fetchImpl(`${prodUrl}/healthcheck`);
  } catch (e) {
    return {
      title,
      state: "down",
      lines: [`unreachable: ${e instanceof Error ? e.message : String(e)}`],
    };
  }

  let checks: Record<string, boolean> = {};
  let overall: string | undefined;
  try {
    const body = (await response.json()) as { status?: string; checks?: Record<string, boolean> };
    overall = body.status;
    checks = body.checks ?? {};
  } catch {
    // Non-JSON body (e.g. an intermediary error page); the HTTP status still tells the story.
  }

  const lines: string[] = [];
  for (const [name, ok] of Object.entries(checks)) {
    lines.push(`${name}: ${ok ? "ok" : "FAILING"}`);
  }
  if (response.ok && overall === "ok") {
    return { title, state: "ok", lines: lines.length > 0 ? lines : ["ok"] };
  }
  lines.unshift(`HTTP ${response.status}${overall ? ` (status: ${overall})` : ""}`);
  return { title, state: "down", lines };
}

async function checkJobs(prodUrl: string, config: AdminConfig, fetchImpl: typeof fetch): Promise<StatusSection> {
  const title = "Jobs & metrics (/metrics)";
  const token = config.values.HARMONIC_METRICS_TOKEN;
  if (token === undefined) {
    return {
      title,
      state: "no-access",
      lines: ["no access to metrics — HARMONIC_METRICS_TOKEN is not set"],
    };
  }

  let response: Response;
  try {
    response = await fetchImpl(`${prodUrl}/metrics`, { headers: { Authorization: `Bearer ${token}` } });
  } catch (e) {
    return {
      title,
      state: "no-access",
      lines: [`metrics unreachable: ${e instanceof Error ? e.message : String(e)}`],
    };
  }
  if (!response.ok) {
    return {
      title,
      state: "no-access",
      lines: [
        `no access to metrics — HTTP ${response.status}` +
          (response.status === 503 ? " (METRICS_AUTH_TOKEN not set on the server?)" : ""),
      ],
    };
  }

  const summary = summarizeSidekiq(parsePrometheusText(await response.text()));
  const lines: string[] = [];
  if (summary.waitingTotal !== undefined) {
    lines.push(`sidekiq waiting: ${summary.waitingTotal}${formatQueues(summary.waitingByQueue)}`);
  }
  if (summary.retry !== undefined) lines.push(`sidekiq retry: ${summary.retry}`);
  if (summary.dead !== undefined) lines.push(`sidekiq dead: ${summary.dead}`);
  if (summary.activeWorkers !== undefined) lines.push(`sidekiq active workers: ${summary.activeWorkers}`);
  if (lines.length === 0) {
    return { title, state: "warn", lines: ["metrics endpoint responded but exposed no sidekiq gauges"] };
  }
  const state: SectionState = (summary.dead ?? 0) > 0 ? "warn" : "ok";
  return { title, state, lines };
}

function formatQueues(byQueue: Record<string, number>): string {
  const parts = Object.entries(byQueue).map(([queue, count]) => `${queue}: ${count}`);
  return parts.length > 0 ? ` (${parts.join(", ")})` : "";
}

async function checkErrors(config: AdminConfig, fetchImpl: typeof fetch): Promise<StatusSection> {
  const title = "Errors (Sentry, unresolved)";
  const missing = (["SENTRY_API_TOKEN", "SENTRY_ORG", "SENTRY_PROJECT"] as const).filter(
    (key) => config.values[key] === undefined,
  );
  if (missing.length > 0) {
    return {
      title,
      state: "no-access",
      lines: [`no access to Sentry — missing ${missing.join(", ")}`],
    };
  }

  const client = new SentryClient({
    baseUrl: config.values.SENTRY_BASE_URL ?? "https://sentry.io",
    org: config.values.SENTRY_ORG as string,
    project: config.values.SENTRY_PROJECT as string,
    apiToken: config.values.SENTRY_API_TOKEN as string,
    fetchImpl,
  });

  let issues;
  try {
    issues = await client.listUnresolvedIssues();
  } catch (e) {
    return {
      title,
      state: "no-access",
      lines: [e instanceof Error ? e.message : String(e)],
    };
  }

  if (issues.length === 0) {
    return { title, state: "ok", lines: ["no unresolved issues"] };
  }
  const top = [...issues].sort((a, b) => b.count - a.count).slice(0, 5);
  const lines = [
    `${issues.length} unresolved issue${issues.length === 1 ? "" : "s"}`,
    ...top.map(
      (issue) =>
        `${issue.shortId}  ${issue.title}  — ${issue.count} events` +
        (issue.userCount !== undefined ? `, ${issue.userCount} users` : "") +
        (issue.lastSeen ? `, last seen ${issue.lastSeen}` : ""),
    ),
  ];
  return { title, state: "warn", lines };
}
