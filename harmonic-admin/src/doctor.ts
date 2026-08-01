// `doctor` — acts locally only. Reports which credentials/sources are
// configured and where each value came from. Secret values are never
// written to output; non-secret values (URLs, org/project slugs) are shown.

import type { Writable } from "node:stream";
import { CONFIG_KEYS, SECRET_KEYS, type AdminConfig } from "./config.js";

export function runDoctor(config: AdminConfig, stdout: Writable): number {
  stdout.write(`Config file: ${config.path}${config.fileExists ? "" : " (does not exist)"}\n\n`);

  for (const key of CONFIG_KEYS) {
    const value = config.values[key];
    const source = config.sources[key];
    let display: string;
    if (value === undefined) {
      display = "not set";
    } else if (SECRET_KEYS.includes(key)) {
      display = `set (${source})`;
    } else {
      display = `${value} (${source})`;
    }
    stdout.write(`${key.padEnd(24)} ${display}\n`);
  }

  stdout.write("\n");
  stdout.write(readiness("prod status", missingFor(config, [])) + " (availability always; metrics and Sentry sections need their keys)\n");
  stdout.write(readiness("prod sentry", missingFor(config, ["SENTRY_API_TOKEN", "SENTRY_ORG", "SENTRY_PROJECT"])) + "\n");
  return 0;
}

function missingFor(config: AdminConfig, keys: readonly (typeof CONFIG_KEYS)[number][]): string[] {
  return keys.filter((key) => config.values[key] === undefined);
}

function readiness(command: string, missing: string[]): string {
  if (missing.length === 0) return `${command.padEnd(24)} ready`;
  return `${command.padEnd(24)} missing ${missing.join(", ")}`;
}
