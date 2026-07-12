#!/bin/bash
# Deploy the latest images to production.
# Run this on the production server after CI has built new images.
#
# Usage:
#   ./scripts/deploy.sh --skip-migrations
#   ./scripts/deploy.sh --with-migrations
#
# With migrations, the order is migrate FIRST, then start the app containers.
# Rails caches each table's column list at boot; migrating under an
# already-running process leaves it generating SQL against the old schema
# (e.g. eager loads selecting a dropped column by name) until restarted.
# The migration runs in a one-off container from the newly pulled image, so
# it sees the new migration files; the long-running containers then boot
# against the migrated schema.

set -e
cd "$(dirname "$0")/.."

COMPOSE_FILE="docker-compose.production.yml"

if [ "$1" = "--with-migrations" ]; then
  RUN_MIGRATIONS=true
elif [ "$1" = "--skip-migrations" ]; then
  RUN_MIGRATIONS=false
else
  echo "Usage: $0 --with-migrations | --skip-migrations"
  echo ""
  echo "  --with-migrations   Pull, run database migrations, then restart"
  echo "  --skip-migrations   Pull and restart only"
  exit 1
fi

echo "Pulling latest images..."
docker compose -f "$COMPOSE_FILE" pull

if [ "$RUN_MIGRATIONS" = true ]; then
  echo "Running database migrations (one-off container, new image)..."
  docker compose -f "$COMPOSE_FILE" run --rm web bundle exec rails db:migrate
fi

echo "Restarting containers..."
docker compose -f "$COMPOSE_FILE" up -d

echo ""
echo "Deploy complete."
