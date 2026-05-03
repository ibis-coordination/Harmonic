#!/bin/bash
# Deploy the latest images to production.
# Run this on the production server after CI has built new images.
#
# Usage:
#   ./scripts/deploy.sh --skip-migrations
#   ./scripts/deploy.sh --with-migrations

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
  echo "  --with-migrations   Pull, restart, then run database migrations"
  echo "  --skip-migrations   Pull and restart only"
  exit 1
fi

echo "Pulling latest images..."
docker compose -f "$COMPOSE_FILE" pull

echo "Restarting containers..."
docker compose -f "$COMPOSE_FILE" up -d

if [ "$RUN_MIGRATIONS" = true ]; then
  echo "Running database migrations..."
  docker compose -f "$COMPOSE_FILE" exec web bundle exec rails db:migrate
fi

echo ""
echo "Deploy complete."
