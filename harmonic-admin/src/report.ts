// `prod report` — run the same checks as `prod status` and post the digest
// into Harmonic as a note, authored by the steward. Acts over HTTPS: the
// status sources (healthcheck, /metrics, Sentry) plus one POST to the
// markdown-UI create_note action in the configured reporting collective.
//
// Posting uses HARMONIC_STEWARD_REPORT_TOKEN — the steward's content token
// (create scope, no admin flag) — never the admin read token. Members of the
// reporting collective are notified through Harmonic's own notification
// mechanics; the CLI adds nothing bespoke.

import type { AdminConfig } from "./config.js";
import { runProdStatus, type ProdStatusResult, type StatusSection } from "./status.js";

export interface ProdReportResult {
  /** Mirror of prod status: 0 up, 1 down — a posted report does not mask a down instance. */
  readonly exitCode: number;
  readonly posted: boolean;
  /** The create_note action response, verbatim markdown (contains the note link). */
  readonly response: string | undefined;
  readonly digest: string;
  readonly error: string | undefined;
}

export interface RunProdReportOpts {
  readonly fetchImpl?: typeof fetch;
}

const STATE_LABELS = {
  ok: "ok",
  warn: "warn",
  down: "DOWN",
  "no-access": "no access",
} as const;

export function renderReportMarkdown(status: ProdStatusResult, generatedAt: Date): string {
  const lines: string[] = [];
  lines.push(`Generated ${generatedAt.toISOString()} by harmonic-admin prod report.`);
  lines.push("");
  for (const section of status.sections) {
    lines.push(`## ${section.title} — ${STATE_LABELS[section.state]}`);
    lines.push("");
    for (const line of section.lines) {
      lines.push(`- ${line}`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

export function overallState(status: ProdStatusResult): string {
  if (status.sections.some((s: StatusSection) => s.state === "down")) return "DOWN";
  if (status.sections.some((s: StatusSection) => s.state === "warn")) return "warn";
  return "ok";
}

export async function runProdReport(config: AdminConfig, opts: RunProdReportOpts = {}): Promise<ProdReportResult> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const status = await runProdStatus(config, { fetchImpl });
  const generatedAt = new Date();
  const digest = renderReportMarkdown(status, generatedAt);

  const missing: string[] = [];
  if (config.values.HARMONIC_STEWARD_REPORT_TOKEN === undefined) missing.push("HARMONIC_STEWARD_REPORT_TOKEN");
  if (config.values.HARMONIC_REPORT_COLLECTIVE === undefined) missing.push("HARMONIC_REPORT_COLLECTIVE");
  if (missing.length > 0) {
    return {
      exitCode: 1,
      posted: false,
      response: undefined,
      digest,
      error: `cannot post report — missing ${missing.join(", ")} (see steward:enable_reporting in docs/STEWARD_AGENTS.md)`,
    };
  }

  const prodUrl = (config.values.HARMONIC_PROD_URL ?? "https://www.harmonic.social").replace(/\/$/, "");
  const collective = config.values.HARMONIC_REPORT_COLLECTIVE;
  const title = `Status report ${generatedAt.toISOString().slice(0, 16).replace("T", " ")} UTC — ${overallState(status)}`;

  let response: Response;
  try {
    response = await fetchImpl(`${prodUrl}/collectives/${collective}/note/actions/create_note`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.values.HARMONIC_STEWARD_REPORT_TOKEN}`,
        Accept: "text/markdown",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ title, text: digest }).toString(),
      redirect: "manual",
    });
  } catch (e) {
    return {
      exitCode: 1,
      posted: false,
      response: undefined,
      digest,
      error: `failed to post report — ${e instanceof Error ? e.message : String(e)}`,
    };
  }

  if (!response.ok) {
    return {
      exitCode: 1,
      posted: false,
      response: undefined,
      digest,
      error: `failed to post report — HTTP ${response.status} from create_note`,
    };
  }

  return {
    exitCode: status.exitCode,
    posted: true,
    response: await response.text(),
    digest,
    error: undefined,
  };
}
