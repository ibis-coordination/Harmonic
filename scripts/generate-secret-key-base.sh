#!/bin/bash
cd "$(dirname "$0")/.."

set -e

docker compose exec web bundle exec rails secret
echo "Copy the above secret into your .env file"
