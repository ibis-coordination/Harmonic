#!/bin/bash
cd "$(dirname "$0")/.."

set -e

echo -e "Cleaning up Docker resources..."

# Remove stopped containers, unused networks, dangling images, and build cache
docker system prune -f
docker builder prune -f

echo -e "Cleanup complete."
