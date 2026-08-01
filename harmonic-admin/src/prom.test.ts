import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePrometheusText, summarizeSidekiq } from "./prom.js";

const SAMPLE = `# HELP sidekiq_jobs_waiting_count The number of jobs waiting to process in all queues.
# TYPE sidekiq_jobs_waiting_count gauge
sidekiq_jobs_waiting_count{queue="default"} 3
sidekiq_jobs_waiting_count{queue="mailers"} 0
# TYPE sidekiq_jobs_retry_count gauge
sidekiq_jobs_retry_count 2
# TYPE sidekiq_jobs_dead_count gauge
sidekiq_jobs_dead_count 7
# TYPE sidekiq_active_workers_count gauge
sidekiq_active_workers_count 1
# TYPE rails_requests_total counter
rails_requests_total{controller="notes",action="index",status="200"} 1500
`;

test("parsePrometheusText: parses names, labels, and values, skipping comments", () => {
  const samples = parsePrometheusText(SAMPLE);
  const waiting = samples.filter((s) => s.name === "sidekiq_jobs_waiting_count");
  assert.equal(waiting.length, 2);
  assert.deepEqual(waiting[0]?.labels, { queue: "default" });
  assert.equal(waiting[0]?.value, 3);
  const retry = samples.find((s) => s.name === "sidekiq_jobs_retry_count");
  assert.deepEqual(retry?.labels, {});
  assert.equal(retry?.value, 2);
});

test("parsePrometheusText: tolerates label values containing commas and escaped quotes", () => {
  const samples = parsePrometheusText('m{a="x,y",b="q\\"z"} 1\n');
  assert.deepEqual(samples[0]?.labels, { a: "x,y", b: 'q"z' });
});

test("parsePrometheusText: skips malformed lines rather than throwing", () => {
  const samples = parsePrometheusText("not a metric line at all\nm 5\n");
  assert.equal(samples.length, 1);
  assert.equal(samples[0]?.name, "m");
});

test("summarizeSidekiq: totals waiting per queue plus retry/dead/workers", () => {
  const summary = summarizeSidekiq(parsePrometheusText(SAMPLE));
  assert.equal(summary.waitingTotal, 3);
  assert.deepEqual(summary.waitingByQueue, { default: 3, mailers: 0 });
  assert.equal(summary.retry, 2);
  assert.equal(summary.dead, 7);
  assert.equal(summary.activeWorkers, 1);
});

test("summarizeSidekiq: absent families come back undefined, not zero", () => {
  const summary = summarizeSidekiq(parsePrometheusText("rails_requests_total 5\n"));
  assert.equal(summary.waitingTotal, undefined);
  assert.equal(summary.retry, undefined);
  assert.equal(summary.dead, undefined);
  assert.equal(summary.activeWorkers, undefined);
  assert.deepEqual(summary.waitingByQueue, {});
});
