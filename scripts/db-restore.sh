#!/bin/bash
cd "$(dirname "$0")/.."

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <backup-file>"
  exit 1
fi

backup_file=$1

docker compose exec web bundle exec rails db:restore[$backup_file]
echo -e "Database restored from $backup_file"