#!/bin/bash
cd "$(dirname "$0")/.."

set -e

echo -e "Restarting Rails in web container..."
docker compose exec web bundle exec rails restart
echo -e "Done"
