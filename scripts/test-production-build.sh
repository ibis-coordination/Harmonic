#!/bin/bash
#
# Test the production Docker build locally
#
# Usage:
#   ./scripts/test-production-build.sh          # Build and run on port 3002
#   ./scripts/test-production-build.sh --build-only  # Just build, don't run
#
cd "$(dirname "$0")/.."

set -e

IMAGE_NAME="harmonic:local-prod-test"
CONTAINER_NAME="harmonic-prod-test"
PORT=3002

# Load credentials from .env
POSTGRES_USER=$(grep -E "^POSTGRES_USER=" .env | cut -d'=' -f2 | tr -d ' ')
POSTGRES_PASSWORD=$(grep -E "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2 | tr -d ' ')
POSTGRES_DB=$(grep -E "^POSTGRES_DB=" .env | cut -d'=' -f2 | tr -d ' ')

echo "Building production image..."
docker build -f Dockerfile.production -t $IMAGE_NAME .

if [ "$1" = "--build-only" ]; then
    echo ""
    echo "Build complete. Image tagged as: $IMAGE_NAME"
    exit 0
fi

echo ""
echo "Starting production container on port $PORT..."
echo "Using your existing dev database and redis (make sure dev containers are running)"
echo ""

# Check if dev containers are running
if ! docker compose ps db --status running -q > /dev/null 2>&1; then
    echo "Error: Dev database container not running. Start dev first with ./scripts/start.sh"
    exit 1
fi

# Clean up any existing test container
docker rm -f $CONTAINER_NAME 2>/dev/null || true

# Get the IP addresses of db and redis containers
DB_IP=$(docker inspect harmonicteam-db-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -c 15)
REDIS_IP=$(docker inspect harmonicteam-redis-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -c 15)

# Run on frontend network for port access, with direct IPs for db/redis
docker run -d \
    --name $CONTAINER_NAME \
    --network harmonicteam_frontend \
    --add-host=db:$DB_IP \
    --add-host=redis:$REDIS_IP \
    -e DATABASE_URL=postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB} \
    -e REDIS_URL=redis://redis:6379/0 \
    -e SECRET_KEY_BASE=test-secret-key-base-at-least-64-chars-long-for-testing-purposes-only \
    -e RAILS_ENV=production \
    -e HOSTNAME=localhost \
    -e PRIMARY_SUBDOMAIN=app \
    -e AUTH_SUBDOMAIN=auth \
    -e AUTH_MODE=oauth \
    -e DO_SPACES_ACCESS_KEY_ID=dummy \
    -e DO_SPACES_SECRET_ACCESS_KEY=dummy \
    -e DO_SPACES_REGION=nyc3 \
    -e DO_SPACES_BUCKET=dummy \
    -e DO_SPACES_ENDPOINT=https://nyc3.digitaloceanspaces.com \
    -p $PORT:3000 \
    $IMAGE_NAME

# Also connect to backend for proper routing
docker network connect harmonicteam_backend $CONTAINER_NAME 2>/dev/null || true

echo ""
echo "Container started. Waiting for healthcheck..."
sleep 5

# Check healthcheck
if curl -sf http://localhost:$PORT/healthcheck > /dev/null; then
    echo "✓ Healthcheck passed!"
    echo ""
    echo "Production container running at http://localhost:$PORT"
    echo "View logs: docker logs -f $CONTAINER_NAME"
    echo "Stop: docker rm -f $CONTAINER_NAME"
else
    echo "✗ Healthcheck failed after 5s. Waiting 5 more seconds..."
    sleep 5
    if curl -sf http://localhost:$PORT/healthcheck > /dev/null; then
        echo "✓ Healthcheck passed!"
        echo ""
        echo "Production container running at http://localhost:$PORT"
        echo "View logs: docker logs -f $CONTAINER_NAME"
        echo "Stop: docker rm -f $CONTAINER_NAME"
    else
        echo "✗ Healthcheck failed. Checking logs..."
        docker logs $CONTAINER_NAME
        docker rm -f $CONTAINER_NAME
        exit 1
    fi
fi
