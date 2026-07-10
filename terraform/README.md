# Harmonic infrastructure (Terraform — Tier 1, provision-only)

> **Status: skeleton / draft for review.** `terraform fmt` and
> `terraform validate` pass (v1.9, real provider schemas), but these configs
> have not been `terraform apply`-ed against a live account. Treat resource
> arguments as a starting point to validate with `terraform plan`, not as
> battle-tested.

This module provisions the **cloud primitives** a Harmonic deployment needs and
bootstraps Docker on the host. It deliberately stops there: it does **not** pull
images, run migrations, or orchestrate the release. That stays with
`scripts/deploy.sh`, which already handles drain/migrate/maintenance-mode —
things Terraform models badly. See [`docs/INFRASTRUCTURE.md`](../docs/INFRASTRUCTURE.md)
for the full rationale and the secrets architecture.

## What it creates

| Resource | Provider | Notes |
|---|---|---|
| Droplet (Ubuntu, Docker via cloud-init) | DigitalOcean | the app host |
| Managed Postgres cluster + db + user | DigitalOcean | external/managed, as the docs assume |
| Spaces bucket + scoped access key | DigitalOcean | ActiveStorage |
| DNS zone + A (root) + wildcard A | DigitalOcean | `*.<domain>` covers all tenant subdomains |
| Cloud firewall (80/443 public, SSH locked) | DigitalOcean | `:8080`/metrics never exposed |
| SES domain identity + DKIM + SPF | AWS (+ DO DNS) | the only AWS usage |

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in
export DIGITALOCEAN_TOKEN=...
export SPACES_ACCESS_KEY_ID=...  SPACES_SECRET_ACCESS_KEY=...
export AWS_ACCESS_KEY_ID=...     AWS_SECRET_ACCESS_KEY=...   # SES only

terraform init
terraform plan
terraform apply

# Then seed your secrets from outputs, into your PRIVATE store (outside this
# repo). Early-boot ones (POSTGRES_*, SMTP, REDIS) go into the server .env;
# the rest are one file per name in secrets/secrets.example, populated on the
# box under secrets/run/ by your chosen adapter. Then run scripts/deploy.sh.
terraform output -raw postgres_password
terraform output -raw spaces_access_key_id
```

## State contains credentials — encrypt it

Managed Postgres and Spaces hand back generated credentials, so they land in
Terraform **state**. Use the encrypted remote backend (commented in
`versions.tf`) before a real apply. App / third-party secrets (Stripe, SES SMTP,
`SECRET_KEY_BASE`, …) are kept **out** of state entirely — they flow through the
file-secrets contract, never a Terraform resource. See the infra doc.

## Not in scope (yet)

- Host config management beyond first-boot cloud-init (Tier 2 — Ansible/richer
  cloud-init for `.env`/secrets templating, backups, monitoring).
- Multi-node / load-balanced / orchestrated topology (Tier 3 — punted as
  over-engineering at single-droplet scale).
