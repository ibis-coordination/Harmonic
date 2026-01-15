#!/bin/bash
cd "$(dirname "$0")/.."

set -e

# remove server.pid if exists to avoid error
rm -f tmp/pids/server.pid

# Load HOST_MODE from .env
HOST_MODE=$(grep -E "^HOST_MODE=" .env | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ')

# Start with caddy profile if HOST_MODE is caddy
if [ "$HOST_MODE" = "caddy" ]; then
    docker compose --profile caddy up -d
else
    docker compose up -d
fi

echo -e "Harmonic Team is now running on http://localhost:3000"
echo -e "To stop Harmonic Team, run ./scripts/stop.sh"
