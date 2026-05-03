#!/bin/bash
# Build and push production Docker images for AMD64.
# Run this on your dev machine when CI is unavailable.
#
# Prerequisites:
#   docker login ghcr.io (see docs/DEPLOYMENT.md)
#
# Usage:
#   ./scripts/hotfix-build.sh              # Push as :latest
#   ./scripts/hotfix-build.sh v1.11.1      # Push as :latest and :v1.11.1

set -e
cd "$(dirname "$0")/.."

REGISTRY="ghcr.io/ibis-coordination"
TAG="${1:-}"

docker buildx create --use --name harmonic-builder 2>/dev/null || \
  docker buildx use harmonic-builder 2>/dev/null || true

echo "Building harmonic (web/sidekiq) for linux/amd64..."
TAGS="-t $REGISTRY/harmonic:latest"
[ -n "$TAG" ] && TAGS="$TAGS -t $REGISTRY/harmonic:$TAG"
docker buildx build --platform linux/amd64 -f Dockerfile.production $TAGS \
  --cache-from type=registry,ref=$REGISTRY/harmonic:buildcache \
  --cache-to type=registry,ref=$REGISTRY/harmonic:buildcache,mode=max \
  --push .

echo ""
echo "Building harmonic-agent-runner for linux/amd64..."
TAGS="-t $REGISTRY/harmonic-agent-runner:latest"
[ -n "$TAG" ] && TAGS="$TAGS -t $REGISTRY/harmonic-agent-runner:$TAG"
docker buildx build --platform linux/amd64 -f agent-runner/Dockerfile $TAGS \
  --cache-from type=registry,ref=$REGISTRY/harmonic-agent-runner:buildcache \
  --cache-to type=registry,ref=$REGISTRY/harmonic-agent-runner:buildcache,mode=max \
  --push ./agent-runner

echo ""
echo "Done. Deploy on prod: ./scripts/deploy.sh"
