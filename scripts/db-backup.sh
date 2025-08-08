#!/bin/bash
cd "$(dirname "$0")/.."

set -e

echo -e "Backing up database to db/backups ..."
output=$(docker compose exec web bundle exec rails db:backup)
echo -e "$output"