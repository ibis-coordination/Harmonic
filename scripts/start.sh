#!/bin/bash
cd "$(dirname "$0")/.."

set -e

# remove server.pid if exists to avoid error
rm -f tmp/pids/server.pid

docker compose up -d
echo -e "Harmonic Team is now running on http://localhost:3000"
echo -e "To stop Harmonic Team, run ./scripts/stop.sh"
