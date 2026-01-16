#!/bin/bash
cd "$(dirname "$0")/.."

set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Compose files for development setup
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.dev.yml"

# Functions
function check_dependency() {
  if ! command -v $1 &> /dev/null; then
    echo -e "${RED}Error:${NC} $1 is not installed. Please install $1 first."
    exit 1
  fi
}

function wait_for_db() {
  echo "Waiting for the database to become available..."
  until docker compose $COMPOSE_FILES exec db pg_isready &> /dev/null; do
    sleep 1
  done
}

# Check dependencies
check_dependency docker

# Build Docker images and start containers
echo -e "${GREEN}Building Docker images and starting containers...${NC}"
docker compose $COMPOSE_FILES build
docker compose $COMPOSE_FILES up -d

# Wait for the database to become available
wait_for_db

# Ensure the database is created and has the correct schema
echo -e "${GREEN}Setting up the database...${NC}"
docker compose $COMPOSE_FILES exec web bundle exec rails db:create db:schema:load db:migrate db:seed

# Sorbet RBI files are committed to the repo.
# To regenerate after gem/model changes, run:
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml exec web bundle exec tapioca gems
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml exec web bundle exec tapioca dsl
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml exec web bundle exec tapioca annotations

echo -e "${GREEN}Setup completed. Removing containers...${NC}"
docker compose $COMPOSE_FILES down

echo -e "${GREEN}Setup completed. You can now start the app with ./scripts/start.sh${NC}"
