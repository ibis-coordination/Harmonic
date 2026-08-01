// Read-only Sentry API client. Acts over HTTPS against the Sentry API;
// needs a token with project:read / event:read / org:read only. Token
// values never appear in output or error messages.

export interface SentryClientOpts {
  readonly baseUrl: string;
  readonly org: string;
  readonly project: string;
  readonly apiToken: string;
  readonly fetchImpl?: typeof fetch;
}

export interface SentryIssue {
  readonly id: string;
  readonly shortId: string;
  readonly title: string;
  readonly culprit: string | undefined;
  readonly level: string | undefined;
  readonly count: number;
  readonly userCount: number | undefined;
  readonly firstSeen: string | undefined;
  readonly lastSeen: string | undefined;
  readonly permalink: string | undefined;
}

export interface SentryEvent {
  readonly dateCreated: string | undefined;
  readonly message: string | undefined;
  readonly tags: Record<string, string>;
}

export interface SentryIssueDetail {
  readonly issue: SentryIssue;
  readonly latestEvent: SentryEvent | undefined;
}

export class SentryClient {
  private readonly opts: SentryClientOpts;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: SentryClientOpts) {
    this.opts = opts;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  async listUnresolvedIssues(limit = 25): Promise<SentryIssue[]> {
    const { baseUrl, org, project } = this.opts;
    const url =
      `${baseUrl}/api/0/projects/${org}/${project}/issues/` +
      `?query=${encodeURIComponent("is:unresolved")}&limit=${limit}`;
    const raw = await this.getJson(url);
    if (!Array.isArray(raw)) throw new Error("Sentry returned an unexpected issue list shape");
    return raw.map((item) => toIssue(item as Record<string, unknown>));
  }

  async getIssue(idOrShortId: string): Promise<SentryIssueDetail> {
    const { baseUrl } = this.opts;
    const id = /^\d+$/.test(idOrShortId) ? idOrShortId : await this.resolveShortId(idOrShortId);
    const issueRaw = await this.getJson(`${baseUrl}/api/0/issues/${encodeURIComponent(id)}/`);
    const issue = toIssue(issueRaw as Record<string, unknown>);
    let latestEvent: SentryEvent | undefined;
    try {
      const eventRaw = await this.getJson(`${baseUrl}/api/0/issues/${encodeURIComponent(id)}/events/latest/`);
      latestEvent = toEvent(eventRaw as Record<string, unknown>);
    } catch {
      latestEvent = undefined;
    }
    return { issue, latestEvent };
  }

  private async resolveShortId(shortId: string): Promise<string> {
    const { baseUrl, org } = this.opts;
    const raw = await this.getJson(`${baseUrl}/api/0/organizations/${org}/shortids/${encodeURIComponent(shortId)}/`);
    const groupId = (raw as Record<string, unknown>).groupId;
    if (typeof groupId !== "string" || groupId === "") {
      throw new Error(`Sentry could not resolve short id "${shortId}" to an issue`);
    }
    return groupId;
  }

  private async getJson(url: string): Promise<unknown> {
    const response = await this.fetchImpl(url, {
      headers: { Authorization: `Bearer ${this.opts.apiToken}` },
    });
    if (response.status === 401 || response.status === 403) {
      throw new Error(
        "Sentry rejected the API token (HTTP " +
          response.status +
          "). Check SENTRY_API_TOKEN and its scopes (project:read, event:read, org:read).",
      );
    }
    if (!response.ok) {
      throw new Error(`Sentry API request failed: HTTP ${response.status} for ${url}`);
    }
    return await response.json();
  }
}

function toIssue(raw: Record<string, unknown>): SentryIssue {
  return {
    id: String(raw.id ?? ""),
    shortId: String(raw.shortId ?? raw.id ?? ""),
    title: String(raw.title ?? "(untitled)"),
    culprit: optionalString(raw.culprit),
    level: optionalString(raw.level),
    count: Number(raw.count ?? 0),
    userCount: typeof raw.userCount === "number" ? raw.userCount : undefined,
    firstSeen: optionalString(raw.firstSeen),
    lastSeen: optionalString(raw.lastSeen),
    permalink: optionalString(raw.permalink),
  };
}

function toEvent(raw: Record<string, unknown>): SentryEvent {
  const tags: Record<string, string> = {};
  if (Array.isArray(raw.tags)) {
    for (const tag of raw.tags) {
      if (tag && typeof tag === "object" && "key" in tag && "value" in tag) {
        tags[String((tag as Record<string, unknown>).key)] = String((tag as Record<string, unknown>).value);
      }
    }
  }
  return {
    dateCreated: optionalString(raw.dateCreated),
    message: optionalString(raw.message),
    tags,
  };
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value !== "" ? value : undefined;
}
