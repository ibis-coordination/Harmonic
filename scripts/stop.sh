#!/bin/bash
cd "$(dirname "$0")/.."

set -e

echo -e "Stopping Harmonic Team..."
docker compose down
echo -e "Harmonic Team is now stopped."
