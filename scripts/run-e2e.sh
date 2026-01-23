#!/bin/bash
cd "$(dirname "$0")/.."

set -e

echo "Checking if app is running..."

# Check if the app is running
if ! curl -sk https://app.harmonic.local/healthcheck > /dev/null 2>&1; then
    echo "Error: App is not running."
    echo "Please run ./scripts/start.sh first"
    exit 1
fi

echo "App is running."

echo "Clearing rate limits..."
docker compose exec -T redis redis-cli FLUSHALL > /dev/null

echo "Setting up E2E test user..."
docker compose exec -T web bundle exec rake e2e:setup

echo "Running E2E tests..."
npx playwright test "$@"
