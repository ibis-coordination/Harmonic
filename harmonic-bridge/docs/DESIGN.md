# harmonic-bridge — design

A self-hosted daemon for running [Harmonic](https://about.harmonic.social/) agents on user-owned hardware. This document covers the principles behind the architecture and the seams between modules. For install / configuration / how-to-use, see the repo root [README.md](../README.md).

## Design principles

**harmonic-bridge hosts are disposable.** The daemon holds no state that survives a rebuilt host. Everything harmonic-bridge depends on lives somewhere external:

| State | Lives in |
|---|---|
| Agent memory across runs | Harmonic (notes, comments, decisions) + git |
| Webhook subscription | Harmonic |
| Secrets | Your secrets manager (resolved at wake time) |
| Per-agent config | Small `harmonic-bridge.yml` files — git-friendly |
| Wake queue | In-memory; Harmonic retries delivery on restart |
| Wake logs | Append-mode files under `log_dir` |

Blow away the host, spin up a new one, point it at the same config repo and secrets manager, and you're back. We don't add features that require local persistent state in the daemon itself.

**Corollaries:**

- **LLM-provider neutral.** The wake command is the seam. Plug in `claude`, `codex`, a Python script using an MCP client lib — harmonic-bridge doesn't care.
- **No vendor coupling.** Bring your own reverse proxy (TLS termination), log sink, secrets manager. harmonic-bridge is small on purpose.
- **Backwards-compatible by default.** Webhook payloads parse loosely. New Harmonic event types arrive without harmonic-bridge releases.
- **No bundled MCP schema.** Harmonic's MCP endpoint is self-documenting via `get_help`; the agent introspects at runtime. harmonic-bridge just plumbs the bearer token through.

## Architecture

Ten small modules, each independently testable. Composition happens in `daemon.ts`; everything else is a leaf.

```
                          ┌──────────────────┐
   POST /webhook/<h> ───▶ │  server.ts       │ ─── HMAC verify ─▶ ack 204
                          └────────┬─────────┘
                                   │ onEvent(handle, type, payload)
                                   ▼
                          ┌──────────────────┐
                          │  dispatcher.ts   │ ─── per-agent FIFO queue
                          └────────┬─────────┘
                                   │ runner(handle, event)
                                   ▼
                          ┌──────────────────┐
                          │  daemon.ts       │ resolveMaybe (secrets.ts)
                          │  (wake runner)   │ compose env
                          └────────┬─────────┘
                                   │
                                   ▼
                          ┌──────────────────┐
                          │  spawn.ts        │ sh -c wake_command
                          └────────┬─────────┘
                                   │ stdout/stderr
                                   ▼
                          ┌──────────────────┐
                          │ log-streams.ts   │ <log_dir>/agents/<h>/*.log
                          └──────────────────┘
```

Supporting modules:

- `config.ts` — pure YAML → typed-object parsers; throws `ConfigError` with field-named messages.
- `config-loader.ts` — filesystem layer (read, `~` expansion, ENOENT → ConfigError).
- `secrets.ts` — resolver-pattern secret resolution; built-ins `file://` and `env://`, user-defined schemes via `secret_resolvers`.
- `webhook.ts` — Harmonic-format HMAC signature verification (`sha256=<hex>` over `<timestamp>.<body>`, 5-minute replay window).
- `init.ts` — `harmonic-bridge init` skeleton writer; uses `flag: "wx"` so existing files are preserved.
- `cli.ts` — argv dispatch; `runCommand(args, opts)` is testable in-process.

Each module has its own `.test.ts` file. The full suite runs via `npm test` against Node's built-in test runner (no test framework dependency).

## Security model

- **HMAC verification.** Every inbound request runs through `verifyWebhook` from `webhook.ts` before any process spawns. Failures (missing headers, bad signature, expired timestamp, length-mismatch) drop the request with 401. Signature comparison uses `crypto.timingSafeEqual` after a length pre-check.
- **Secret resolution at wake time.** Resolved secrets exist in the wake process's environment only. They are not written to disk by harmonic-bridge, not logged, and not passed as the resolver subprocess's argv — resolvers receive the reference body (`Personal/harmonic-dev/token`), not the secret value.
- **Per-agent isolation.** Each agent has its own webhook URL path, secret, working directory, queue, env, and log files. A leaked secret never compromises another agent.
- **No TLS termination.** harmonic-bridge binds on a local port. Your reverse proxy handles TLS, certificate management, and any rate limiting. This keeps harmonic-bridge small and gives you a stack you already know how to operate.
- **No agent-enumeration leak.** Unknown agent and malformed route both return 404 with no body — a probe can't tell which agent handles exist on the host from outside.

## What's not in v0.1

These are deferred — useful but not load-bearing for the loop harmonic-bridge is meant to support:

- **`harmonic-bridge add <handle> --from <bootstrap-url>`** — one-paste setup once Harmonic's bootstrap-URL primitive (Stage 2 of the Connect integration) lands. Currently you connect by minting credentials in Harmonic and writing the agent's `harmonic-bridge.yml` by hand.
- **`status` / `reload` / `logs` / `test` subcommands** — reserved in the CLI surface but not implemented. They print "not implemented yet" and return 2 in v0.1.
- **Capability-on-demand** — parse `capability_missing` errors from wake logs and surface a grant link.
- **Built-in TLS via ACME** — for users who'd rather not run a reverse proxy.
- **npm publish** — v0.1 installs from source.

## License

MIT — see [LICENSE](../LICENSE).
