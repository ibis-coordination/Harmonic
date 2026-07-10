# Secrets: interface, not store

Harmonic is open source and deployed by many operators. **No secret material —
plaintext or ciphertext — lives in this repo.** What the repo ships is the
*interface* for supplying secrets; the material itself is bring-your-own and
stays private to your deployment.

## The interface

- **`secrets.example`** — the contract: the names of the infra / third-party
  secrets Harmonic expects. No values.
- **`config/initializers/00_file_secrets.rb`** — reads each `/run/secrets/<NAME>`
  into `ENV[NAME]`, but only when the env var isn't already set (strict no-op
  where the mount is absent).
- **`docker-compose.secrets.yml`** — overlay that mounts `secrets/run/<NAME>`
  into `/run/secrets/<NAME>` (tmpfs) for the services that need each secret.
- **`scripts/deploy.sh`** — populates secrets via a *swappable, guarded hook*
  that defaults to a no-op, then enables the overlay only if secrets are present.

## Supplying the material (two ways)

1. **Pre-place the files (default).** Put one 0600 file per name from
   `secrets.example` under `secrets/run/` (gitignored) — via `scp`,
   configuration management, or your password manager's CLI. No hook needed.

   > When the overlay is enabled, **every** file-mounted name needs a file —
   > compose errors on a missing source. Leave a file **empty** to keep that
   > secret on the legacy `.env` path (the initializer ignores empty files).
   > Not every secret can move: early-boot and compose-interpolated ones
   > (`POSTGRES_*`, `SMTP_PASSWORD`, `REDIS_*`) stay in `.env` for now — see
   > `secrets.example` and the infra doc's boot-ordering caveat.

2. **Install a populate hook.** Point `SECRETS_HOOK` (default
   `/opt/harmonic/secrets/populate-secrets.sh`) at an executable that writes
   those files from your private source at deploy time. Example adapters live in
   [`adapters/`](adapters/) — copy one **out of this repo**, wire it to your own
   private source, and install it on the server. The repo ships no hook, so this
   is opt-in.

`secrets/run/`, keys, and any real secret files are gitignored — see the repo
root `.gitignore`. Never commit secret material here, encrypted or not.

See [`docs/INFRASTRUCTURE.md`](../docs/INFRASTRUCTURE.md) for the full rationale
and the app-internal vs infra/third-party split.
