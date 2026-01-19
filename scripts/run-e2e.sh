#!/bin/bash
cd "$(dirname "$0")/.."

set -e

echo "Checking if app is running..."

# Check if the app is running
if ! curl -sk https://app.harmonic.local/healthcheck > /dev/null 2>&1; then
    echo "Error: App is not running."
    echo "Please run ./scripts/start.sh first"
    echo "Make sure AUTH_MODE=honor_system in your .env file"
    exit 1
fi

echo "App is running."

# Check AUTH_MODE (optional warning)
AUTH_MODE=$(docker compose exec -T web bash -c 'echo $AUTH_MODE' 2>/dev/null || echo "unknown")
if [ "$AUTH_MODE" != "honor_system" ]; then
    echo "Warning: AUTH_MODE is '$AUTH_MODE', not 'honor_system'"
    echo "E2E tests require AUTH_MODE=honor_system. Tests may fail."
    echo "Set AUTH_MODE=honor_system in .env and restart the app."
    echo ""
fi

echo "Running E2E tests..."
npx playwright test "$@"
