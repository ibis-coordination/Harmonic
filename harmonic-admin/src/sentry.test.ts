import { test } from "node:test";
import assert from "node:assert/strict";
import { SentryClient } from "./sentry.js";

const ISSUE_FIXTURE = {
  id: "123456",
  shortId: "HARMONIC-42",
  title: "NoMethodError: undefined method `foo' for nil",
  culprit: "NotesController#create",
  level: "error",
  count: "17",
  userCount: 3,
  firstSeen: "2026-07-30T01:02:03Z",
  lastSeen: "2026-07-31T09:08:07Z",
  permalink: "https://sentry.io/organizations/ibis/issues/123456/",
};

const EVENT_FIXTURE = {
  dateCreated: "2026-07-31T09:08:07Z",
  message: "undefined method `foo' for nil",
  tags: [
    { key: "environment", value: "production" },
    { key: "release", value: "1.63.0" },
  ],
};

interface RecordedRequest {
  url: string;
  headers: Record<string, string>;
}

function fakeFetch(routes: Record<string, unknown>, recorded: RecordedRequest[]): typeof fetch {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    recorded.push({ url, headers: (init?.headers ?? {}) as Record<string, string> });
    const path = url.split("?")[0] ?? url;
    for (const [route, body] of Object.entries(routes)) {
      if (path === route) {
        return new Response(JSON.stringify(body), { status: 200 });
      }
    }
    return new Response("not found", { status: 404 });
  }) as typeof fetch;
}

function client(routes: Record<string, unknown>, recorded: RecordedRequest[]): SentryClient {
  return new SentryClient({
    baseUrl: "https://sentry.io",
    org: "ibis",
    project: "harmonic",
    apiToken: "tok-secret",
    fetchImpl: fakeFetch(routes, recorded),
  });
}

test("listUnresolvedIssues: hits the project issues endpoint with bearer auth", async () => {
  const recorded: RecordedRequest[] = [];
  const c = client({ "https://sentry.io/api/0/projects/ibis/harmonic/issues/": [ISSUE_FIXTURE] }, recorded);
  const issues = await c.listUnresolvedIssues();
  assert.equal(issues.length, 1);
  assert.equal(issues[0]?.shortId, "HARMONIC-42");
  assert.equal(issues[0]?.count, 17);
  const request = recorded[0];
  assert.ok(request);
  assert.match(request.url, /query=is%3Aunresolved/);
  assert.equal(request.headers["Authorization"], "Bearer tok-secret");
});

test("getIssue: fetches issue detail plus latest event", async () => {
  const recorded: RecordedRequest[] = [];
  const c = client(
    {
      "https://sentry.io/api/0/issues/123456/events/latest/": EVENT_FIXTURE,
      "https://sentry.io/api/0/issues/123456/": ISSUE_FIXTURE,
    },
    recorded,
  );
  const detail = await c.getIssue("123456");
  assert.equal(detail.issue.title, ISSUE_FIXTURE.title);
  assert.equal(detail.latestEvent?.message, EVENT_FIXTURE.message);
  assert.deepEqual(detail.latestEvent?.tags, { environment: "production", release: "1.63.0" });
});

test("getIssue: missing latest event degrades to issue detail alone", async () => {
  const recorded: RecordedRequest[] = [];
  const c = client({ "https://sentry.io/api/0/issues/123456/": ISSUE_FIXTURE }, recorded);
  const detail = await c.getIssue("123456");
  assert.equal(detail.issue.shortId, "HARMONIC-42");
  assert.equal(detail.latestEvent, undefined);
});

test("getIssue: resolves a short id via the org shortids endpoint", async () => {
  const recorded: RecordedRequest[] = [];
  const c = client(
    {
      "https://sentry.io/api/0/organizations/ibis/shortids/HARMONIC-42/": { groupId: "123456" },
      "https://sentry.io/api/0/issues/123456/": ISSUE_FIXTURE,
      "https://sentry.io/api/0/issues/123456/events/latest/": EVENT_FIXTURE,
    },
    recorded,
  );
  const detail = await c.getIssue("HARMONIC-42");
  assert.equal(detail.issue.id, "123456");
  assert.equal(detail.latestEvent?.message, EVENT_FIXTURE.message);
});

test("getIssue: numeric ids skip shortid resolution", async () => {
  const recorded: RecordedRequest[] = [];
  const c = client({ "https://sentry.io/api/0/issues/123456/": ISSUE_FIXTURE }, recorded);
  await c.getIssue("123456");
  assert.ok(!recorded.some((r) => r.url.includes("/shortids/")));
});

test("errors: 401 explains the token was rejected without echoing it", async () => {
  const failFetch = (async () => new Response("unauthorized", { status: 401 })) as typeof fetch;
  const c = new SentryClient({
    baseUrl: "https://sentry.io",
    org: "ibis",
    project: "harmonic",
    apiToken: "tok-secret",
    fetchImpl: failFetch,
  });
  await assert.rejects(
    () => c.listUnresolvedIssues(),
    (e: Error) => {
      assert.match(e.message, /Sentry rejected the API token/);
      assert.ok(!e.message.includes("tok-secret"));
      return true;
    },
  );
});
