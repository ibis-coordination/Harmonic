// Minimal Prometheus text-format parsing, enough to summarize the gauges
// that yabeda-sidekiq exports from /metrics. Malformed lines are skipped:
// a partial digest beats a crashed status command.

export interface PromSample {
  readonly name: string;
  readonly labels: Record<string, string>;
  readonly value: number;
}

export function parsePrometheusText(text: string): PromSample[] {
  const samples: PromSample[] = [];
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    const sample = parseSampleLine(trimmed);
    if (sample) samples.push(sample);
  }
  return samples;
}

function parseSampleLine(line: string): PromSample | undefined {
  const match = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{.*\})?\s+(\S+)/.exec(line);
  if (!match) return undefined;
  const [, name, labelBlock, rawValue] = match;
  if (name === undefined || rawValue === undefined) return undefined;
  const value = Number(rawValue);
  if (Number.isNaN(value)) return undefined;
  return { name, labels: labelBlock ? parseLabels(labelBlock) : {}, value };
}

function parseLabels(block: string): Record<string, string> {
  // block is `{key="value",...}`; values may contain escaped quotes.
  const labels: Record<string, string> = {};
  const re = /([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"/g;
  for (const match of block.matchAll(re)) {
    const [, key, raw] = match;
    if (key === undefined || raw === undefined) continue;
    labels[key] = raw.replace(/\\(.)/g, "$1");
  }
  return labels;
}

export interface SidekiqSummary {
  readonly waitingTotal: number | undefined;
  readonly waitingByQueue: Record<string, number>;
  readonly retry: number | undefined;
  readonly dead: number | undefined;
  readonly activeWorkers: number | undefined;
}

export function summarizeSidekiq(samples: readonly PromSample[]): SidekiqSummary {
  const waitingByQueue: Record<string, number> = {};
  let waitingTotal: number | undefined;
  for (const s of samples) {
    if (s.name !== "sidekiq_jobs_waiting_count") continue;
    waitingTotal = (waitingTotal ?? 0) + s.value;
    const queue = s.labels.queue;
    if (queue !== undefined) waitingByQueue[queue] = (waitingByQueue[queue] ?? 0) + s.value;
  }
  return {
    waitingTotal,
    waitingByQueue,
    retry: sumFamily(samples, "sidekiq_jobs_retry_count"),
    dead: sumFamily(samples, "sidekiq_jobs_dead_count"),
    activeWorkers: sumFamily(samples, "sidekiq_active_workers_count"),
  };
}

function sumFamily(samples: readonly PromSample[], name: string): number | undefined {
  let total: number | undefined;
  for (const s of samples) {
    if (s.name === name) total = (total ?? 0) + s.value;
  }
  return total;
}
