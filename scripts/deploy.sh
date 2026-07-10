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

# Directory of per-secret files that the compose `secrets:` overlay mounts to
# /run/secrets/<NAME>. Operator-populated, gitignored — NO secret material,
# plaintext or ciphertext, lives in this repo.
SECRETS_DIR="${SECRETS_DIR:-secrets/run}"

# Optional operator-provided populate hook, sourced from OUTSIDE this repo.
# Its job is to materialize one 0600 file per secret under $SECRETS_DIR from a
# bring-your-own source. The repo ships NO hook by default, so this is a strict
# no-op until an operator installs one. Example adapters (SOPS+age, AWS SSM,
# Vault agent) live in secrets/adapters/ — copy one out of the repo, fill in
# your private source, and point $SECRETS_HOOK at it. See docs/INFRASTRUCTURE.md.
SECRETS_HOOK="${SECRETS_HOOK:-/opt/harmonic/secrets/populate-secrets.sh}"

# Populate file-mounted secrets and enable the overlay — but only when the
# operator has opted in (a populate hook exists, or files are already present).
# Absent → strict no-op, so the legacy .env path is unaffected.
populate_secrets() {
  if [ -x "$SECRETS_HOOK" ]; then
    echo "Populating secrets via hook: $SECRETS_HOOK"
    SECRETS_DIR="$SECRETS_DIR" "$SECRETS_HOOK"
  fi

  if [ -d "$SECRETS_DIR" ] && [ -n "$(ls -A "$SECRETS_DIR" 2>/dev/null)" ]; then
    COMPOSE_FILES+=(-f docker-compose.secrets.yml)
  fi
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

populate_secrets

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
