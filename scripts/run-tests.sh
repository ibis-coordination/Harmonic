#!/bin/bash
cd "$(dirname "$0")/.."

set -e

# Stop autoheal to prevent container restarts during tests
# (healthcheck can fail under heavy test load, triggering unwanted restarts)
echo "Stopping autoheal service..."
docker compose stop autoheal 2>/dev/null || true

# Ensure autoheal is restarted on exit (success or failure)
cleanup() {
  echo ""
  echo "Restarting autoheal service..."
  docker compose start autoheal 2>/dev/null || true
}
trap cleanup EXIT

echo "Running backend tests..."
docker compose exec web bundle exec rails test

echo ""
echo "Running frontend tests..."
docker compose exec js npm test

echo ""
echo "Running MCP server tests..."
cd mcp-server && npm test