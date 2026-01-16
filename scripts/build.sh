#!/bin/bash
cd "$(dirname "$0")/.."

set -e

# Load environment variables from .env
RAILS_ENV=$(grep -E "^RAILS_ENV=" .env | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ')

# Build compose command with appropriate files
COMPOSE_FILES="-f docker-compose.yml"

if [ "$RAILS_ENV" = "production" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.prod.yml"
else
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.dev.yml"
fi

echo -e "Building Harmonic images..."
docker compose $COMPOSE_FILES build "$@"
echo -e "Build complete."
