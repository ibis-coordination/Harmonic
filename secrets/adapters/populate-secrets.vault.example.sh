#!/bin/bash
# EXAMPLE populate hook — HashiCorp Vault / OpenBao adapter. OPTIONAL, not
# installed by default.
#
# This is one way to implement scripts/deploy.sh's $SECRETS_HOOK. It is an
# example: copy it OUT of this repo, point it at YOUR Vault/OpenBao server and
# secret path, and install it on the server (e.g. as
# /opt/harmonic/secrets/populate-secrets.sh, the default $SECRETS_HOOK path).
# Nothing here fetches anything on its own.
#
# Fit: operators already running a secrets manager. (Vault is BUSL-licensed now;
# OpenBao is the OSS fork — the `vault` CLI and API are compatible with both.)
# Over-engineering at single-droplet scale, but the hook contract supports it.
#
# The single bootstrapped credential is the box's Vault auth — ideally a short
# scoped token from AppRole/agent, planted at provision time. No age key, no
# encrypted blob, no long-lived cloud key.
#
#   - Store all secrets as fields of ONE KV-v2 secret, e.g.
#     `vault kv put secret/harmonic/prod STRIPE_API_KEY=... GITHUB_CLIENT_SECRET=...`
#   - Each field name must match a NAME from secrets/secrets.example.
#
# deploy.sh calls this with $SECRETS_DIR exported; the job is to write one
# 0600 file per secret into $SECRETS_DIR.
set -euo pipefail

# BYO: your Vault/OpenBao address, auth token, and the KV-v2 secret path.
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-$(cat "${VAULT_TOKEN_FILE:-/opt/harmonic/secrets/vault-token}" 2>/dev/null || true)}"
VAULT_SECRET_PATH="${VAULT_SECRET_PATH:-secret/harmonic/prod}"
SECRETS_DIR="${SECRETS_DIR:-secrets/run}"

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: the 'vault' CLI (Vault or OpenBao) is not installed." >&2
  exit 1
fi
if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "ERROR: no Vault token (set VAULT_TOKEN or VAULT_TOKEN_FILE)." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' is required to parse Vault KV JSON in this example hook." >&2
  exit 1
fi

install -d -m 700 "$SECRETS_DIR"

# Read every field of the KV-v2 secret as "field<TAB>value" lines (data.data
# holds the key/value map), then write one 0600 file per field.
vault kv get -format=json "$VAULT_SECRET_PATH" \
  | jq -r '.data.data | to_entries[] | [.key, .value] | @tsv' \
  | while IFS=$'\t' read -r key value; do
      [ -n "$key" ] || continue
      printf '%s' "$value" > "$SECRETS_DIR/$key"
      chmod 600 "$SECRETS_DIR/$key"
    done

echo "Populated $SECRETS_DIR from Vault path $VAULT_SECRET_PATH"
