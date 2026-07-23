// HTTP server that accepts Harmonic notification webhooks and hands valid
// events off to the dispatcher.
//
// Single route: POST /webhook/<agent-handle>. Looks up the agent, verifies
// the HMAC signature, acks 204 *before* triggering the wake (so Harmonic
// doesn't time out waiting for the actual work). All other methods/paths
// return 405/404 with no body.

import { createServer as createHttpServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { verifyWebhook } from "./webhook.js";

export interface AgentResolution {
  /** Resolved (plaintext) webhook secret for HMAC verification. */
  readonly webhookSecret: string;
}

export interface ServerOpts {
  readonly listen: { readonly host: string; readonly port: number };
  /** Look up an agent by handle. Return null if no such agent. */
  readonly resolveAgent: (handle: string) => Promise<AgentResolution | null>;
  /** Called after signature verification succeeds. */
  readonly onEvent: (handle: string, eventType: string, payload: string) => void;
  /** Override the current epoch-seconds clock. */
  readonly now?: () => number;
  /** Max request body size in bytes. Defaults to 1 MiB. */
  readonly maxBodyBytes?: number;
  /**
   * When set, GET /hold streams heartbeat bytes until the client closes the
   * connection. Used by hold-awake on hibernating hosts: the daemon holds a
   * request against its own public URL while wakes run so the platform's
   * idle detector sees activity. Off by default.
   */
  readonly holdRoute?: { readonly heartbeatMs: number };
  /**
   * Awaited after signature verification, before the 204 ack is written.
   * On hibernating hosts the daemon uses this to establish the hold-awake
   * connection while the inbound webhook connection still pins the machine
   * awake — otherwise establishment races the freeze. Failures are
   * swallowed: a broken hold must not block deliveries.
   */
  readonly beforeAck?: () => Promise<void>;
}

export interface RunningServer {
  /** Actual bound port (useful when port 0 was requested). */
  readonly port: number;
  close(): Promise<void>;
}

const DEFAULT_MAX_BODY_BYTES = 1024 * 1024;
const ROUTE_RE = /^\/webhook\/([a-zA-Z0-9][a-zA-Z0-9_-]*)\/?$/;
const HOLD_ROUTE_RE = /^\/hold\/?$/;
// The /hold route is unauthenticated (the daemon can't sign its own request
// without an agent context, and the exposure is equivalent to what any
// public URL already has — repeated requests keep a hibernating host awake
// regardless). Cap concurrent holds so it can't be used to pile up sockets.
const MAX_HOLD_CONNECTIONS = 16;

export function startServer(opts: ServerOpts): Promise<RunningServer> {
  const maxBodyBytes = opts.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;

  let holdConnections = 0;
  const server = createHttpServer((req, res) => {
    if (opts.holdRoute && req.method === "GET" && req.url && HOLD_ROUTE_RE.test(req.url)) {
      handleHold(res, opts.holdRoute.heartbeatMs, {
        count: () => holdConnections,
        increment: () => (holdConnections += 1),
        decrement: () => (holdConnections -= 1),
      });
      return;
    }
    handleRequest(req, res, opts, maxBodyBytes).catch(() => {
      if (!res.headersSent) {
        res.writeHead(500);
        res.end();
      }
    });
  });

  return new Promise<RunningServer>((resolve, reject) => {
    server.once("error", reject);
    server.listen(opts.listen.port, opts.listen.host, () => {
      server.removeListener("error", reject);
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : opts.listen.port;
      resolve({
        port,
        close: () => closeServer(server),
      });
    });
  });
}

function handleHold(
  res: ServerResponse,
  heartbeatMs: number,
  connections: { count: () => number; increment: () => void; decrement: () => void },
): void {
  if (connections.count() >= MAX_HOLD_CONNECTIONS) {
    res.writeHead(503);
    res.end();
    return;
  }
  connections.increment();
  res.writeHead(200, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
  // Write immediately so the client's request resolves and it knows the
  // hold is established, then keep the stream visibly alive.
  res.write("h\n");
  const beat = setInterval(() => res.write("h\n"), heartbeatMs);
  res.on("close", () => {
    clearInterval(beat);
    connections.decrement();
  });
}

async function handleRequest(
  req: IncomingMessage,
  res: ServerResponse,
  opts: ServerOpts,
  maxBodyBytes: number,
): Promise<void> {
  if (req.method !== "POST") {
    res.writeHead(405);
    res.end();
    return;
  }

  const match = req.url?.match(ROUTE_RE);
  if (!match) {
    res.writeHead(404);
    res.end();
    return;
  }
  const handle = match[1]!;

  const agent = await opts.resolveAgent(handle);
  if (!agent) {
    // Don't leak which handles exist — same response as a malformed route.
    res.writeHead(404);
    res.end();
    return;
  }

  const read = await readBody(req, maxBodyBytes);
  if (read.tooBig) {
    res.writeHead(413);
    res.end();
    return;
  }
  const body = read.body;

  const verification = verifyWebhook({
    body,
    signatureHeader: headerString(req.headers["x-harmonic-signature"]),
    timestampHeader: headerString(req.headers["x-harmonic-timestamp"]),
    secret: agent.webhookSecret,
    now: opts.now ? opts.now() : undefined,
  });

  if (!verification.valid) {
    res.writeHead(401);
    res.end();
    return;
  }

  if (opts.beforeAck) {
    try {
      await opts.beforeAck();
    } catch {
      // A failed pre-ack hook must not block the delivery.
    }
  }

  // Ack before dispatching so Harmonic doesn't time out on slow wakes.
  res.writeHead(204);
  res.end();

  const eventType = headerString(req.headers["x-harmonic-event"]) ?? "unknown";
  opts.onEvent(handle, eventType, body);
}

async function readBody(req: IncomingMessage, maxBytes: number): Promise<{ body: string; tooBig: boolean }> {
  return await new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    let settled = false;
    req.on("data", (chunk: Buffer) => {
      if (settled) return;
      total += chunk.length;
      if (total > maxBytes) {
        // Stop reading and signal the caller. The caller writes 413 + ends
        // the response, which closes the connection cleanly. Destroying the
        // request here would race the response write and the client could
        // see "socket closed" instead of 413.
        settled = true;
        req.pause();
        resolve({ body: "", tooBig: true });
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (settled) return;
      settled = true;
      resolve({ body: Buffer.concat(chunks).toString("utf8"), tooBig: false });
    });
    req.on("error", (err) => {
      if (settled) return;
      settled = true;
      reject(err);
    });
  });
}

function headerString(value: string | string[] | undefined): string | undefined {
  if (value === undefined) return undefined;
  return Array.isArray(value) ? value[0] : value;
}

function closeServer(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((err) => (err ? reject(err) : resolve()));
  });
}
