#!/bin/bash
cd "$(dirname "$0")/.."

set -e

echo -e "Stopping Harmonic Team..."

# Load HOST_MODE from .env
HOST_MODE=$(grep -E "^HOST_MODE=" .env | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ')

# Stop with caddy profile if HOST_MODE is caddy
if [ "$HOST_MODE" = "caddy" ]; then
    docker compose --profile caddy down
else
    docker compose down
fi

echo -e "Harmonic Team is now stopped."
