#!/bin/bash
# Development/Test stop script - NOT for production use
cd "$(dirname "$0")/.."

set -e

# Check for production environment and abort if detected
RAILS_ENV_FROM_ENV=$(grep -E "^RAILS_ENV=" .env 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || true)
if [ "$RAILS_ENV" = "production" ] || [ "$RAILS_ENV_FROM_ENV" = "production" ]; then
    echo "ERROR: This script is for development and test environments only."
    echo ""
    echo "For production deployment, please see the deployment guide:"
    echo "  docs/DEPLOYMENT.md"
    echo ""
    echo "Do not use ./scripts/start.sh or ./scripts/stop.sh in production."
    exit 1
fi

echo -e "Stopping Harmonic..."

# Load HOST_MODE from .env
HOST_MODE=$(grep -E "^HOST_MODE=" .env | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ')

# Add profile for reverse proxy based on HOST_MODE
PROFILES=""
if [ "$HOST_MODE" = "caddy" ]; then
    PROFILES="--profile caddy"
elif [ "$HOST_MODE" = "ngrok" ]; then
    PROFILES="--profile ngrok"
fi

docker compose $PROFILES down --remove-orphans

echo -e "Harmonic is now stopped."
