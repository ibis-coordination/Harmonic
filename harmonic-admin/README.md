# harmonic-admin

Admin CLI for operating Harmonic instances: monitoring today, deployment and
broader sysadmin tasks over time. One well-documented CLI covers everything an
admin (human or agent) needs; capability lives in credentials, not the binary —
a command works iff its credential is present.

## Install

```bash
npm install -g @ibis-coordination/harmonic-admin
```

Or run from the repo:

```bash
cd harmonic-admin && npm install && npm run dev -- doctor
```

## Commands

Every command states where it acts and whether it mutates. Nothing in this
version mutates anything.

| Command | Acts | Description |
|---------|------|-------------|
| `harmonic-admin prod status` | prod over HTTPS + Sentry API | Availability (healthcheck), job backlog (/metrics), and error digest (Sentry) in one view |
| `harmonic-admin prod sentry issues` | Sentry API | Unresolved issues, most recent first |
| `harmonic-admin prod sentry show <id>` | Sentry API | One issue in detail, including the latest event |
| `harmonic-admin doctor` | local only | Which credentials/sources are configured; never prints secret values |

`prod status` degrades gracefully per source: a missing credential produces a
"no access" line for that section, and the rest of the digest still renders.

## Configuration

Credentials live in `~/.config/harmonic-admin/env` (create it with `chmod 600`).
`KEY=VALUE` lines; `#` comments; real environment variables override the file;
`HARMONIC_ADMIN_CONFIG` overrides the file path.

That file holds **read-only, individually-revocable tokens only.** Anything
dangerous (SSH, deploy access) deliberately has no home here.

| Key | Secret | Purpose |
|-----|--------|---------|
| `HARMONIC_PROD_URL` | no | Prod base URL (default `https://www.harmonic.social`; must be the canonical host — a redirect would strip the metrics bearer header) |
| `HARMONIC_METRICS_TOKEN` | yes | Bearer token for the `/metrics` endpoint |
| `SENTRY_API_TOKEN` | yes | Read-only Sentry token (scopes: `project:read`, `event:read`, `org:read`) |
| `SENTRY_ORG` | no | Sentry organization slug |
| `SENTRY_PROJECT` | no | Sentry project slug |
| `SENTRY_BASE_URL` | no | Sentry API base (default `https://sentry.io`) |

The CLI never prints token values — `doctor` reports `set (file)` / `set (env)`
/ `not set` for secret keys.

## Development

```bash
npm test           # node:test via tsx
npm run typecheck  # tsc --noEmit
npm run build      # compile to dist/
```

Releases are published from the monorepo by tagging `admin-vX.Y.Z`.
