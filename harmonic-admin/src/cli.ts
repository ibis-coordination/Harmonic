// CLI dispatch for harmonic-admin. Imported by ./bin.ts (the actual entry
// point) and by tests. No side effects on import — runCommand must be
// invoked explicitly.
//
// Every command here is read-only. Commands under `prod` act over HTTPS
// against the production instance and the Sentry API; `doctor` acts
// locally. Nothing in this CLI prints a credential value.

import type { Writable } from "node:stream";
import { loadConfig, type AdminConfig } from "./config.js";
import { runDoctor } from "./doctor.js";
import { runProdStatus, type StatusSection } from "./status.js";
import { SentryClient } from "./sentry.js";

export interface CliOpts {
  /** Explicit config file path; wins over HARMONIC_ADMIN_CONFIG and the default. */
  readonly configPath?: string;
  /** Environment map. Defaults to process.env. */
  readonly env?: Record<string, string | undefined>;
  readonly fetchImpl?: typeof fetch;
  readonly stdout?: Writable;
  readonly stderr?: Writable;
}

export async function runCommand(args: readonly string[], opts: CliOpts = {}): Promise<number> {
  const stdout = opts.stdout ?? process.stdout;
  const stderr = opts.stderr ?? process.stderr;
  const command = args[0];

  if (command === undefined || command === "help" || command === "--help" || command === "-h") {
    printUsage(stdout);
    return 0;
  }

  const config = await loadConfig({ configPath: opts.configPath, env: opts.env });

  if (command === "doctor") {
    return runDoctor(config, stdout);
  }

  if (command === "prod") {
    return await runProd(args.slice(1), config, opts, stdout, stderr);
  }

  stderr.write(`harmonic-admin: unknown command "${command}"\n`);
  printUsage(stderr);
  return 64;
}

async function runProd(
  args: readonly string[],
  config: AdminConfig,
  opts: CliOpts,
  stdout: Writable,
  stderr: Writable,
): Promise<number> {
  const sub = args[0];

  if (sub === "status") {
    const result = await runProdStatus(config, { fetchImpl: opts.fetchImpl });
    for (const section of result.sections) {
      stdout.write(renderSection(section));
    }
    return result.exitCode;
  }

  if (sub === "page") {
    return await runPage(args.slice(1), config, opts, stdout, stderr);
  }

  if (sub === "sentry") {
    return await runSentry(args.slice(1), config, opts, stdout, stderr);
  }

  stderr.write(`harmonic-admin: unknown command "prod ${sub ?? ""}"\n`);
  printUsage(stderr);
  return 64;
}

// Authenticated pager for prod's markdown pages (system-admin and any other
// page the steward token can read). Prints the body verbatim — never parses
// or re-renders; page structure belongs to Rails.
async function runPage(
  args: readonly string[],
  config: AdminConfig,
  opts: CliOpts,
  stdout: Writable,
  stderr: Writable,
): Promise<number> {
  const path = args[0];
  if (path === undefined) {
    stderr.write('harmonic-admin: "prod page" requires a path (e.g. /system-admin/sidekiq)\n');
    return 64;
  }
  if (!path.startsWith("/")) {
    stderr.write('harmonic-admin: "prod page" takes a path starting with "/", not a full URL\n');
    return 64;
  }

  const token = config.values.HARMONIC_STEWARD_TOKEN;
  if (token === undefined) {
    stderr.write(
      `harmonic-admin: no access to prod pages — set HARMONIC_STEWARD_TOKEN in ${config.path} ` +
        "(read-scope rest token with the sys_admin flag, held by the steward agent)\n",
    );
    return 1;
  }

  const fetchImpl = opts.fetchImpl ?? fetch;
  const prodUrl = (config.values.HARMONIC_PROD_URL ?? "https://www.harmonic.social").replace(/\/$/, "");
  let response: Response;
  try {
    // Never follow redirects: a redirect means we're not getting the page we
    // asked for (wrong host, login bounce), and following one cross-origin
    // would drop the Authorization header anyway. Report it instead.
    response = await fetchImpl(`${prodUrl}${path}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: "text/markdown" },
      redirect: "manual",
    });
  } catch (e) {
    stderr.write(`harmonic-admin: prod unreachable — ${e instanceof Error ? e.message : String(e)}\n`);
    return 1;
  }

  if (response.status >= 300 && response.status < 400) {
    const location = response.headers.get("location") ?? "(no Location header)";
    stderr.write(
      `harmonic-admin: ${path} responded with a redirect (HTTP ${response.status} → ${location}); ` +
        "check HARMONIC_PROD_URL points at the canonical primary host\n",
    );
    return 1;
  }

  if (!response.ok) {
    const hint =
      response.status === 401 || response.status === 403
        ? " (token rejected — the steward token needs read scope, the sys_admin flag, and a sys_admin user)"
        : "";
    stderr.write(`harmonic-admin: HTTP ${response.status} for ${path}${hint}\n`);
    return 1;
  }

  stdout.write(await response.text());
  return 0;
}

async function runSentry(
  args: readonly string[],
  config: AdminConfig,
  opts: CliOpts,
  stdout: Writable,
  stderr: Writable,
): Promise<number> {
  const sub = args[0];
  if (sub !== "issues" && sub !== "show") {
    stderr.write(`harmonic-admin: unknown command "prod sentry ${sub ?? ""}"\n`);
    printUsage(stderr);
    return 64;
  }

  const missing = (["SENTRY_API_TOKEN", "SENTRY_ORG", "SENTRY_PROJECT"] as const).filter(
    (key) => config.values[key] === undefined,
  );
  if (missing.length > 0) {
    stderr.write(
      `harmonic-admin: no access to Sentry — set ${missing.join(", ")} in ${config.path} ` +
        "(read-only token; scopes project:read, event:read, org:read)\n",
    );
    return 1;
  }

  const client = new SentryClient({
    baseUrl: config.values.SENTRY_BASE_URL ?? "https://sentry.io",
    org: config.values.SENTRY_ORG as string,
    project: config.values.SENTRY_PROJECT as string,
    apiToken: config.values.SENTRY_API_TOKEN as string,
    fetchImpl: opts.fetchImpl,
  });

  if (sub === "issues") {
    const issues = await client.listUnresolvedIssues();
    if (issues.length === 0) {
      stdout.write("No unresolved issues.\n");
      return 0;
    }
    for (const issue of issues) {
      stdout.write(
        `${issue.shortId}  [${issue.level ?? "?"}]  ${issue.title}\n` +
          `  ${issue.count} events` +
          (issue.userCount !== undefined ? `, ${issue.userCount} users` : "") +
          (issue.lastSeen ? `, last seen ${issue.lastSeen}` : "") +
          `  (id: ${issue.id})\n`,
      );
    }
    return 0;
  }

  const id = args[1];
  if (id === undefined) {
    stderr.write('harmonic-admin: "prod sentry show" requires an issue id\n');
    return 64;
  }
  const detail = await client.getIssue(id);
  const { issue, latestEvent } = detail;
  stdout.write(`${issue.shortId}  [${issue.level ?? "?"}]  ${issue.title}\n`);
  if (issue.culprit) stdout.write(`culprit:    ${issue.culprit}\n`);
  stdout.write(`events:     ${issue.count}` + (issue.userCount !== undefined ? ` (${issue.userCount} users)` : "") + "\n");
  if (issue.firstSeen) stdout.write(`first seen: ${issue.firstSeen}\n`);
  if (issue.lastSeen) stdout.write(`last seen:  ${issue.lastSeen}\n`);
  if (issue.permalink) stdout.write(`link:       ${issue.permalink}\n`);
  if (latestEvent) {
    stdout.write("\nLatest event:\n");
    if (latestEvent.dateCreated) stdout.write(`  at:      ${latestEvent.dateCreated}\n`);
    if (latestEvent.message) stdout.write(`  message: ${latestEvent.message}\n`);
    for (const [key, value] of Object.entries(latestEvent.tags)) {
      stdout.write(`  ${key}: ${value}\n`);
    }
  }
  return 0;
}

const STATE_BADGES = {
  ok: "[ok]",
  warn: "[warn]",
  down: "[DOWN]",
  "no-access": "[no access]",
} as const;

function renderSection(section: StatusSection): string {
  const lines = [`${STATE_BADGES[section.state]} ${section.title}`];
  for (const line of section.lines) {
    lines.push(`  ${line}`);
  }
  return lines.join("\n") + "\n\n";
}

function printUsage(out: Writable): void {
  out.write(`Usage: harmonic-admin <command>

Commands:
  doctor                    Local: report which credentials/sources are configured.
                            Never prints secret values.
  prod status               HTTPS to prod + Sentry API: availability, job backlog,
                            and error digest in one view. Read-only.
  prod page <path>          HTTPS to prod: fetch a markdown page as the steward
                            agent and print it verbatim (e.g. /system-admin/sidekiq).
                            Read-only.
  prod sentry issues        Sentry API: unresolved issues, most recent first. Read-only.
  prod sentry show <id>     Sentry API: one issue in detail. Read-only.

No command here mutates anything. Commands under \`prod\` act over HTTPS with
read-only tokens; \`doctor\` acts locally only.

Configuration (~/.config/harmonic-admin/env, chmod 600; KEY=VALUE lines;
real environment variables override; HARMONIC_ADMIN_CONFIG overrides the path):
  HARMONIC_PROD_URL         Prod base URL (default https://www.harmonic.social)
  HARMONIC_METRICS_TOKEN    Bearer token for /metrics (secret)
  HARMONIC_STEWARD_TOKEN    Steward agent's read-scope rest token for markdown pages (secret)
  SENTRY_API_TOKEN          Read-only Sentry token (secret; project:read, event:read, org:read)
  SENTRY_ORG                Sentry organization slug
  SENTRY_PROJECT            Sentry project slug
  SENTRY_BASE_URL           Sentry API base (default https://sentry.io)
`);
}
