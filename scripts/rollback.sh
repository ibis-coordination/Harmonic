#!/bin/bash
# Roll back production to a previous image version.
# Run this on the production server.
#
# Usage:
#   ./scripts/rollback.sh <image_tag>
#
# Examples:
#   ./scripts/rollback.sh v1.11.0
#   ./scripts/rollback.sh amd64-425821cb7f12d627e6c66eded...
#
# Find available tags at:
#   https://github.com/orgs/ibis-coordination/packages/container/harmonic/versions

set -e
cd "$(dirname "$0")/.."

COMPOSE_FILE="docker-compose.production.yml"
REGISTRY="ghcr.io/ibis-coordination"

if [ -z "$1" ]; then
  echo "Usage: $0 <image_tag>"
  echo ""
  echo "Examples:"
  echo "  $0 v1.11.0"
  echo "  $0 amd64-425821cb7f12d6..."
  echo ""
  echo "Find tags: https://github.com/orgs/ibis-coordination/packages/container/harmonic/versions"
  exit 1
fi

TAG="$1"

echo "Pulling harmonic:$TAG..."
docker pull "$REGISTRY/harmonic:$TAG"

echo "Pulling harmonic-agent-runner:$TAG..."
docker pull "$REGISTRY/harmonic-agent-runner:$TAG"

echo "Tagging as :latest..."
docker tag "$REGISTRY/harmonic:$TAG" "$REGISTRY/harmonic:latest"
docker tag "$REGISTRY/harmonic-agent-runner:$TAG" "$REGISTRY/harmonic-agent-runner:latest"

echo "Restarting containers..."
docker compose -f "$COMPOSE_FILE" up -d

echo ""
echo "Rolled back to: $TAG"
