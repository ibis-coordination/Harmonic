/**
 * HTTP transport for talking to the Harmonic Rails app.
 *
 * Why this module exists
 * ----------------------
 * Node.js built-in `fetch` (which uses undici under the hood) derives the
 * `Host` header from the request URL and silently ignores any `Host` value
 * set in `headers`. That is a problem because:
 *
 *   - We need to open TCP to the Rails container by its internal name/port
 *     (e.g. `web:3000`). It isn't reachable by tenant hostname without going
 *     through the public reverse proxy, and the proxy blocks `/internal/*`.
 *   - Rails must see `Host: <tenant>.<hostname>` (e.g. `app.harmonic.local`)
 *     so tenant resolution by subdomain works the same way it does for
 *     external user requests.
 *
 * With `fetch`, those two concerns are coupled — the URL decides both. So
 * this module drops down to undici's lower-level `Client.request` API, which
 * lets us say "connect to web:3000" separately from "put this in the Host
 * header". The `Client` is bound to the Rails container's internal URL; each
 * request sets `host` in its headers to identify the tenant.
 *
 * Naming note: undici's `Client`
 * ------------------------------
 * `Client` here is undici's name for an HTTP connection pool bound to one
 * origin. It is NOT related to the `HarmonicClient` service (which makes
 * agent API requests on behalf of AI agents), and it is NOT related to the
 * "AI agents" (User records with user_type: "ai_agent") that this service
 * runs tasks for. Three overlapping vocabularies. Variables here use
 * `railsClient` / `internalClient` to keep the HTTP-level concept distinct
 * from the agent-level concepts; the `Client` identifier only appears at
 * import.
 */

import { Client } from "undici";
import type { Dispatcher } from "undici";
import { Context, Effect, Layer } from "effect";
import { Config } from "../config/Config.js";

export interface RailsResponse {
  readonly statusCode: number;
  readonly text: () => Promise<string>;
}

export interface RailsRequestOptions {
  readonly method: "GET" | "POST" | "PUT" | "DELETE";
  readonly subdomain: string;
  readonly path: string;
  readonly headers?: Record<string, string>;
  readonly body?: string;
  readonly timeoutMs?: number;
}

export interface RailsHttpService {
  readonly request: (opts: RailsRequestOptions) => Promise<RailsResponse>;
}

export class RailsHttp extends Context.Tag("RailsHttp")<RailsHttp, RailsHttpService>() {}

export const RailsHttpLive = Layer.effect(
  RailsHttp,
  Effect.gen(function* () {
    const config = yield* Config;

    const railsClient = new Client(config.harmonicInternalUrl);

    const request: RailsHttpService["request"] = async (opts) => {
      const normalizedPath = opts.path.startsWith("/") ? opts.path : `/${opts.path}`;
      const hostHeader = `${opts.subdomain}.${config.harmonicHostname}`;
      const timeoutMs = opts.timeoutMs ?? 30_000;

      // `host` must be set explicitly — undici treats this header as the HTTP
      // Host and does NOT derive it from the URL when using Client.request
      // (unlike fetch, which overrides any Host header with the URL hostname).
      const requestOpts: Dispatcher.RequestOptions = {
        method: opts.method,
        path: normalizedPath,
        headers: {
          ...(opts.headers ?? {}),
          host: hostHeader,
        },
        headersTimeout: timeoutMs,
        bodyTimeout: timeoutMs,
      };
      if (opts.body !== undefined) {
        requestOpts.body = opts.body;
      }

      const res: Dispatcher.ResponseData = await railsClient.request(requestOpts);
      return {
        statusCode: res.statusCode,
        text: () => res.body.text(),
      };
    };

    return { request };
  }),
);
