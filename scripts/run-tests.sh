#!/bin/bash
cd "$(dirname "$0")/.."

set -e

echo "Running backend tests..."
docker compose exec web bundle exec rails test

echo ""
echo "Running frontend tests..."
docker compose exec js npm test