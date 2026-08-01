# harmonic-admin CLI

**Status: settled direction, compressed 2026-07-31. One well-documented CLI
for instance operations — `dev` (local dev + GitHub) and `prod` (deploy /
monitoring / admin / comms) contexts. v1 is the basics below; everything
else is listed as later work, one line each.**

## Settled decisions

- **TypeScript, in-repo `harmonic-admin/`, bridge conventions** — npm
  `@ibis-coordination/harmonic-admin`, published by tagging `admin-vX.Y.Z`,
  installable on sprites like the bridge.
- **Capability lives in credentials, not the binary.** Same CLI everywhere;
  a command works iff its credential is present. Deploy needs server
  presence/SSH (Dan-only, deliberately). Status needs read-only tokens.
- **Credentials home**: `~/.config/harmonic-admin/env` (chmod 600, env vars
  override) on laptops and the prod host; bridge secrets backend on sprites.
  That file holds **read-only, individually-revocable tokens only** — agents
  share the OS user, so this tier is readable by them; the dangerous tier
  (SSH/deploy) stays password-gated and in no file. The CLI never prints
  token values.
- **Every command's help states where it acts** (local / GitHub /
  prod-over-HTTPS / prod-server-side) and whether it mutates.
- **Wraps existing scripts, doesn't rewrite them.**

## v1 — the basics

```
harmonic-admin prod status            # healthcheck + metrics + Sentry digest
harmonic-admin prod sentry issues     # unresolved issues, frequency
harmonic-admin prod sentry show <id>  # one issue in detail
harmonic-admin doctor                 # which credentials/sources are configured (values masked)
```

`prod status` degrades gracefully per source (missing credential → "no
access to X").

*Acceptance:* from a laptop, no SSH, "how's prod doing?" gets a grounded
answer covering availability, error state, and job backlog in one command.

**Prod facts (2026-07-31):** Sentry, Slack security alerts, and UptimeRobot
are live. `METRICS_AUTH_TOKEN` is not set — `/metrics` 503s until Dan sets
one (`openssl rand -hex 32`, prod `.env`, restart web); not blocking, status
runs on healthcheck + Sentry meanwhile.

**Dan-side setup:** mint a read-only Sentry API token (`project:read`,
`event:read`, `org:read`) → `~/.config/harmonic-admin/env`; set the metrics
token when convenient.

## Later (each one line, in rough order)

- `prod report` — post the digest as a note + notification (the steward's
  comms primitive).
- Steward wakes: sprite agent + scheduled rule + Sentry-alert → inbound
  automation webhook; runs the same commands, reports to Dan.
- `prod deploy|rollback|maintenance|caddyfile` — wrap the server-side
  scripts; prod host installs the CLI from npm instead of copied scripts.
- `dev start|stop|test|console|checks` — wrap local scripts.
- `--target staging|admin` once those instances exist.
- UptimeRobot API in the digest; log aggregation (trigger: first
  investigation that dead-ends without request logs); metrics history
  (trigger: first trend question a snapshot can't answer).
- Into-Harmonic migration (Harmonic holds vendor tokens server-side; agents
  use their own scoped tokens) — the eventual "agents use secrets without
  reading them" answer; trigger: cross-instance work begins.
