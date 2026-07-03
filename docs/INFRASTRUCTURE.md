# Infrastructure & Secrets Architecture

> **Status:** draft / skeleton, posted for review on
> [note 1cc7cc50](https://www.harmonic.social/collectives/harmonic-devs/n/1cc7cc50).
> Statically validated (`terraform validate` against real provider schemas,
> shellcheck, compose-merge check) — but nothing here has been
> `terraform apply`-ed against a live account or exercised on a real deploy
> yet. Review it as a proposal, not a battle-tested tool.

This document covers how Harmonic infrastructure is provisioned and how secrets
are handled. It accompanies the `terraform/` module, the `secrets/` directory,
`docker-compose.secrets.yml`, and `config/initializers/00_file_secrets.rb`.

## The shape of the problem

Today the **release** path is already reproducible and IaC-shaped: CI builds
multi-arch images on a `v*` tag → `scripts/deploy.sh` does `compose pull && up`;
`rollback.sh`, the auto-generated Caddyfile, and scripted maintenance mode round
it out. The gap is **provisioning + first-boot config** — currently prose in
`DEPLOYMENT.md` ("clone or copy these files to your server"): spin up a VPS,
install Docker, provision managed Postgres, create the Spaces bucket, set up SES
+ DKIM/SPF, add wildcard DNS, and hand-assemble `.env`.

So the design splits cleanly by tool:

| Layer | Tool | Why |
|---|---|---|
| Cloud primitives (VPS, managed PG, Spaces, DNS, firewall, SES) | **Terraform** | declarative, drift-detectable, one `apply` recreates the stack |
| Host bootstrap (install Docker, drop compose files) | **cloud-init** | Terraform is bad at in-place config mgmt; provisioners are an anti-pattern |
| App release + migrations + maintenance mode | **`deploy.sh`** (unchanged) | Terraform can't orchestrate drain/migrate/rolling restart |

We start at **Tier 1 (provision-only)**. Tier 2 (Ansible/cloud-init templating
`.env`, backups, monitoring) and Tier 3 (Swarm/k8s orchestration — over-
engineering at single-droplet scale) are explicitly deferred.

## Secrets: two separable decisions

"Replace `.env`" is really two independent choices. Most of the pain comes from
conflating them.

### Axis 1 — injection: how a running container receives a secret

Today: environment variables. Env vars leak independently of where the secret is
stored — they show up in `docker inspect`, `/proc/<pid>/environ`, inherited child
processes, crash dumps, and error reporters (Sentry attaches process env to
reports). The fix is **file-mounted secrets**: Compose `secrets:` blocks mount
each value into `/run/secrets/<NAME>` (tmpfs, absent from the image and from
`inspect`). Rails reads them via `config/initializers/00_file_secrets.rb`, which
sets `ENV[name]` from `/run/secrets/<name>` **only when the env var isn't already
set**. Precedence: explicit ENV > file > unset. That makes it a strict no-op on
any host without `/run/secrets` (dev, test, today's prod), so we can migrate one
secret at a time.

This axis costs nothing and needs no new infra. `docker-compose.secrets.yml` is
an **overlay** so the env path keeps working until the team opts in.

**Scope.** Only secrets Rails reads *after* initializers run can move to the
overlay today: Spaces secret key, Stripe keys, GitHub OAuth secret, Turnstile
key, and the Rails-side `AGENT_RUNNER_SECRET`. The rest are pinned to the
legacy `.env` path for now, for two mechanical reasons:

- **Read too early.** `SMTP_*` and `REDIS_URL` are read in
  `config/environments/production.rb`, and `POSTGRES_*` in `database.yml` ERB —
  all *before* `config/initializers/*` run, so the file-secrets initializer
  fires too late. See "Boot-ordering caveat" below.
- **Compose interpolation.** `REDIS_PASSWORD` and agent-runner's
  `AGENT_RUNNER_SECRET` appear as `${VAR:?…}` in
  `docker-compose.production.yml` (redis `--requirepass`, healthcheck,
  agent-runner env) — compose resolves those from the *host* env/`.env` at
  `up` time; a container file mount can't satisfy them. agent-runner is Node
  and reads `process.env` directly, so moving it also needs an entrypoint
  export.

The existing `agent-runner` service already enumerates its env vars explicitly
(instead of `env_file: .env`) to keep its blast radius small; the overlay
leaves it untouched.

One compose gotcha, documented in the overlay header: when the overlay is
enabled every declared secret file must exist (compose errors on a missing
source). To migrate one secret at a time, create the full set and leave a file
**empty** for any secret staying on `.env` — the initializer ignores empty
files, so the env var still wins.

### Axis 2 — storage / root of trust

> **Governing constraint (non-negotiable).** Harmonic is an open-source
> codebase deployed by many operators. **No secret material — plaintext or
> ciphertext — may live in this repo**, and the strategy must be deployable by
> anyone in the general case. So the repo ships only an *interface* for
> supplying secrets; each deployment's actual material is bring-your-own and
> stays private (a separate private repo, an object-store object, or planted at
> provision time). Storage is therefore an **operator choice behind a swappable
> hook**, not a value this repo hard-codes.

Every storage scheme (master.key, age key, Vault token, cloud IAM) reduces to
bootstrapping exactly **one** credential onto the server. That bootstrap is the
whole game. Relevant asymmetry: we run on a **DO droplet** (no instance-profile
equivalent) but already use **AWS for SES** (AWS gives instance profiles for
free). That affects which option each operator finds cheapest.

`scripts/deploy.sh` calls a **guarded populate hook** (`$SECRETS_HOOK`,
default `/opt/harmonic/secrets/populate-secrets.sh`) whose job is to write one
file per secret into `$SECRETS_DIR` (`secrets/run/`, gitignored). The repo
ships **no hook**, so the default is a strict no-op; the operator picks how the
material arrives:

| Adapter | Fit |
|---|---|
| **Pre-place files (default)** | Operator drops one 0600 file per secret into `secrets/run/` (scp, config-mgmt, password-manager CLI). Zero dependencies; no hook needed. |
| **SOPS + age** | Encrypt a **private** dotenv file (kept outside this repo), decrypt at deploy with one age key. Version-controlled + encrypted at rest in your private store. Example hook: `secrets/adapters/populate-secrets.sops.example.sh`. Pairs with Tier 1 — **Terraform never sees plaintext**. |
| **AWS SSM Parameter Store** | Viable (we're in AWS), but means an IAM user's static creds on a DO box (an instance role avoids that). A hook runs `aws ssm get-parameters-by-path`. Example hook: `secrets/adapters/populate-secrets.ssm.example.sh`. |
| **Vault agent / OpenBao** | For operators already running one. (Vault is BUSL-licensed now; OpenBao is the OSS fork.) Over-engineering at single-droplet scale, but the hook contract supports it. Example hook: `secrets/adapters/populate-secrets.vault.example.sh`. |
| Rails encrypted credentials | Complementary (see split below), not an Axis-2 adapter. |

harmonic-devs' own deployment will use **SOPS + age**, with the encrypted blob
in a private repo — but that's our operator choice, not a repo default.

### The split we use

- **Infra / third-party** secrets that are read late enough (Spaces secret key,
  Stripe, OAuth, Turnstile) → **file-mounted `/run/secrets/<NAME>`**, populated
  by the operator's chosen adapter. Names listed in `secrets/secrets.example`.
- **Early-boot / compose-interpolated** secrets (`POSTGRES_*`, `SMTP_PASSWORD`,
  `REDIS_PASSWORD`/`REDIS_URL`) → stay in the server `.env` until an
  entrypoint-export step exists (see the scope note above).
- **App-internal** secrets (`SECRET_KEY_BASE`, `AGENT_RUNNER_SECRET`) → **Rails
  encrypted credentials** (`config/credentials.yml.enc`). Different owner, blast
  radius, and rotation cadence.

Secrets are **global** — one shared set of infra/third-party creds across all
tenant subdomains (resolved by
[decision bcf853b3](https://www.harmonic.social/collectives/harmonic-devs/d/bcf853b3);
per-tenant drew zero support). No per-tenant lookup path or per-tenant split.

## Secrets and Terraform state

The one unavoidable plaintext exposure: **managed-resource credentials**
(Postgres password, Spaces key) are generated by the provider and therefore land
in Terraform **state**. Mitigations:

1. Use the **encrypted remote backend** (DO Spaces / `s3` backend — templated in
   `terraform/versions.tf`). Never keep state on a laptop or in git.
2. Keep **everything else out of state**: app and third-party secrets go through
   the file-secrets contract (populated by your adapter), never through a
   `local_file` / templated-`.env` Terraform resource.

This is why keeping secrets out of Terraform matters beyond convenience — it
shrinks the state-plaintext problem down to just the two credentials Terraform
must generate.

## Bootstrapping the one key

Whichever adapter you choose reduces to planting **one** bootstrap credential on
the box. For the SOPS+age adapter that's the age private key; the example hook
looks for it at `/opt/harmonic/secrets/age.key` (override with
`SOPS_AGE_KEY_FILE`). cloud-init creates the (0700) `/opt/harmonic/secrets/`
directory but deliberately plants **no key material** — user-data is itself
visible to the DO API, so the bootstrap credential should be planted
out-of-band after first boot (`scp`, or your password manager's CLI). If you
accept the key living in Terraform state, you can instead template it in via a
sensitive variable — a deliberate trade-off, not the default. Operators who
instead pre-place the plaintext secret files, or use an instance-profile
adapter (SSM), have no long-lived bootstrap key at all.

## Boot-ordering caveat

`00_file_secrets.rb` runs first among `config/initializers/*` (the `00_`
prefix) — but a chunk of Rails boot happens *before* any of those run, and
every ENV read in that window is out of the initializer's reach:

- `config/environments/production.rb` — `SMTP_*` (mailer settings hash),
  `REDIS_URL` (cache store) are read when the environment file loads.
- `config/database.yml` ERB — `POSTGRES_HOST/PORT/DB/USER/PASSWORD` are read
  when the database configuration is built.
- `SECRET_KEY_BASE` — key derivation, earliest of all (kept in Rails
  credentials anyway).

If/when those move to file-secrets, export them in the **container entrypoint**
(read `/run/secrets/<NAME>` into the environment before `rails server` starts)
rather than relying on the initializer. Until that entrypoint exists, the
overlay simply doesn't list them — see the scope note under Axis 1. One
remaining validate-on-boot item: `DO_SPACES_SECRET_ACCESS_KEY` is read via
`config/storage.yml` ERB, which ActiveStorage evaluates lazily (post-
initializers) — confirm on a real boot before dropping it from `.env`.

## End-to-end flow

```
terraform apply                 # cloud primitives + Docker host
  └─ outputs: droplet_ip, postgres_* creds, spaces keys, ...
       │
       ▼
(your PRIVATE store, outside this repo)   # seed secrets from outputs by BYO means
       │                                  # early-boot ones (POSTGRES_*, SMTP, REDIS)
       │                                  #   go into the server .env for now
       ▼  (on the droplet)
scripts/deploy.sh --with-migrations
  ├─ populate_secrets()         # optional $SECRETS_HOOK writes secrets/run/<NAME>
  │                             #   (default: operator pre-placed the files; no-op)
  ├─ docker compose -f prod -f secrets up -d   # overlay enabled only if populated
  │     └─ mounts /run/secrets/<NAME> → 00_file_secrets.rb → ENV
  └─ rails db:migrate
(rollback.sh keeps the same overlay guard, so a rollback doesn't strip secrets)
```

## Decisions & open questions

**Resolved:**

- **No secret material in the repo** — settled by directive: the repo ships only
  the interface; material is bring-your-own and private. This is the governing
  constraint above, not a vote.
- **Secrets scope: global** — one shared set across all tenants
  ([decision bcf853b3](https://www.harmonic.social/collectives/harmonic-devs/d/bcf853b3);
  per-tenant drew zero support).
- **Topology: single-node** — the module stays single-droplet, upgrade-friendly
  ([decision 651b8093](https://www.harmonic.social/collectives/harmonic-devs/d/651b8093)).

**Operator choices (not repo defaults):**

1. **Which adapter** populates `/run/secrets/` — pre-placed files (default),
   SOPS+age, AWS SSM, Vault. See the Axis-2 table; example hook in
   `secrets/adapters/`.
2. **age vs AWS KMS** for operators using the SOPS adapter. age is simplest; KMS
   adds an audit trail but ties decrypt to AWS creds on a DO box.
3. **Secrets *service* (Infisical/SSM) vs file-based** — file-based is the
   simplest starting point; a service is a clean later upgrade behind the same
   hook contract.
