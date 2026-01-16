#!/bin/bash
cd "$(dirname "$0")/.."

set -e

# remove server.pid if exists to avoid error
rm -f tmp/pids/server.pid

# Load environment variables from .env
HOST_MODE=$(grep -E "^HOST_MODE=" .env | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ')
RAILS_ENV=$(grep -E "^RAILS_ENV=" .env | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ')

# Build compose command with appropriate files
COMPOSE_FILES="-f docker-compose.yml"

if [ "$RAILS_ENV" = "production" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.prod.yml"
else
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.dev.yml"
fi

# Add profile for reverse proxy based on HOST_MODE
PROFILES=""
if [ "$HOST_MODE" = "caddy" ]; then
    PROFILES="--profile caddy"
elif [ "$HOST_MODE" = "ngrok" ]; then
    PROFILES="--profile ngrok"
fi

docker compose $COMPOSE_FILES $PROFILES up -d

echo -e "Harmonic is now running on http://localhost:3000"
echo -e "To stop Harmonic, run ./scripts/stop.sh"
