#!/bin/bash
# Deploy the latest images to production.
# Run this on the production server after CI has built new images.
#
# Usage:
#   ./scripts/deploy.sh --skip-migrations
#   ./scripts/deploy.sh --with-migrations

set -e
cd "$(dirname "$0")/.."

COMPOSE_FILES=(-f docker-compose.production.yml)
ENCRYPTED_SECRETS="secrets/secrets.enc.env"
DECRYPTED_DIR="secrets/decrypted"

# Decrypt SOPS-managed secrets into per-key files for the compose `secrets:`
# overlay (docker-compose.secrets.yml). No-op when the encrypted file is
# absent, so the legacy .env path is unaffected. See docs/INFRASTRUCTURE.md.
decrypt_secrets() {
  [ -f "$ENCRYPTED_SECRETS" ] || return 0

  if ! command -v sops >/dev/null 2>&1; then
    echo "ERROR: $ENCRYPTED_SECRETS present but 'sops' is not installed." >&2
    exit 1
  fi

  # The age private key is the one bootstrapped credential (see infra doc).
  export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/opt/harmonic/secrets/age.key}"

  echo "Decrypting secrets -> $DECRYPTED_DIR ..."
  install -d -m 700 "$DECRYPTED_DIR"

  # Decrypt to dotenv, then split into one 0600 file per key.
  local plaintext
  plaintext="$(sops -d --input-type dotenv --output-type dotenv "$ENCRYPTED_SECRETS")"
  while IFS='=' read -r key value; do
    case "$key" in ''|\#*) continue ;; esac
    printf '%s' "$value" > "$DECRYPTED_DIR/$key"
    chmod 600 "$DECRYPTED_DIR/$key"
  done <<< "$plaintext"

  COMPOSE_FILES+=(-f docker-compose.secrets.yml)
}

if [ "$1" = "--with-migrations" ]; then
  RUN_MIGRATIONS=true
elif [ "$1" = "--skip-migrations" ]; then
  RUN_MIGRATIONS=false
else
  echo "Usage: $0 --with-migrations | --skip-migrations"
  echo ""
  echo "  --with-migrations   Pull, restart, then run database migrations"
  echo "  --skip-migrations   Pull and restart only"
  exit 1
fi

decrypt_secrets

echo "Pulling latest images..."
docker compose "${COMPOSE_FILES[@]}" pull

echo "Restarting containers..."
docker compose "${COMPOSE_FILES[@]}" up -d

if [ "$RUN_MIGRATIONS" = true ]; then
  echo "Running database migrations..."
  docker compose "${COMPOSE_FILES[@]}" exec web bundle exec rails db:migrate
fi

echo ""
echo "Deploy complete."
