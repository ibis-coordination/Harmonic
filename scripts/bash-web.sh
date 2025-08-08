#!/bin/bash
cd "$(dirname "$0")/.."

set -e

docker compose exec web bash
