#!/bin/bash
# EXAMPLE populate hook — SOPS + age adapter. OPTIONAL, not installed by default.
#
# This is one way to implement scripts/deploy.sh's $SECRETS_HOOK. It is an
# example: copy it OUT of this repo, point it at YOUR private encrypted file,
# and install it on the server (e.g. as /opt/harmonic/secrets/populate-secrets.sh,
# the default $SECRETS_HOOK path). Nothing here decrypts anything on its own.
#
#   - The encrypted file is bring-your-own and lives OUTSIDE this repo
#     (a private repo, an object-store object, or planted at provision time).
#     Never commit it upstream, even encrypted.
#   - The age private key that unlocks it is the single bootstrapped credential;
#     it lives only on the server and on operators' machines.
#
# deploy.sh calls this with $SECRETS_DIR exported; the job is to write one
# 0600 file per secret into $SECRETS_DIR.
set -euo pipefail

# BYO: path to your SOPS-encrypted dotenv file, OUTSIDE this repo.
SOPS_SECRETS_FILE="${SOPS_SECRETS_FILE:-/opt/harmonic/secrets/secrets.enc.env}"
# The one bootstrapped credential (see docs/INFRASTRUCTURE.md).
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/opt/harmonic/secrets/age.key}"
SECRETS_DIR="${SECRETS_DIR:-secrets/run}"

if [ ! -f "$SOPS_SECRETS_FILE" ]; then
  echo "ERROR: $SOPS_SECRETS_FILE not found (bring-your-own encrypted file)." >&2
  exit 1
fi
if ! command -v sops >/dev/null 2>&1; then
  echo "ERROR: 'sops' is not installed." >&2
  exit 1
fi

install -d -m 700 "$SECRETS_DIR"

# Decrypt to dotenv, then split into one 0600 file per key.
plaintext="$(sops -d --input-type dotenv --output-type dotenv "$SOPS_SECRETS_FILE")"
while IFS='=' read -r key value; do
  case "$key" in ''|\#*) continue ;; esac
  printf '%s' "$value" > "$SECRETS_DIR/$key"
  chmod 600 "$SECRETS_DIR/$key"
done <<< "$plaintext"

echo "Populated $SECRETS_DIR from $SOPS_SECRETS_FILE"
