#!/bin/bash
# Patch files directly in running production containers.
# Run this on the production server for emergency fixes.
#
# The fix takes effect immediately but is temporary — the next
# image deploy will overwrite it.
#
# Usage:
#   ./scripts/hotfix-patch.sh <file> [file...]
#
# Examples:
#   ./scripts/hotfix-patch.sh app/services/automation_dispatcher.rb
#   ./scripts/hotfix-patch.sh app/models/user.rb app/controllers/users_controller.rb

set -e
cd "$(dirname "$0")/.."

COMPOSE_FILE="docker-compose.production.yml"

if [ -z "$1" ]; then
  echo "Usage: $0 <file> [file...]"
  echo "Example: $0 app/services/automation_dispatcher.rb"
  exit 1
fi

# Validate all files exist before patching anything
for FILE_PATH in "$@"; do
  if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File not found: $FILE_PATH"
    exit 1
  fi
done

WEB=$(docker compose -f "$COMPOSE_FILE" ps -q web 2>/dev/null)
SIDEKIQ=$(docker compose -f "$COMPOSE_FILE" ps -q sidekiq 2>/dev/null)

if [ -z "$WEB" ] && [ -z "$SIDEKIQ" ]; then
  echo "Error: No running containers found."
  exit 1
fi

for FILE_PATH in "$@"; do
  echo "Patching $FILE_PATH..."
  [ -n "$WEB" ] && docker cp "$FILE_PATH" "$WEB:/app/$FILE_PATH"
  [ -n "$SIDEKIQ" ] && docker cp "$FILE_PATH" "$SIDEKIQ:/app/$FILE_PATH"
done

echo "Restarting..."
docker compose -f "$COMPOSE_FILE" restart web sidekiq

echo ""
echo "Patched $# file(s). This is temporary — follow up with a proper deploy."
