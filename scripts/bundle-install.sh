#!/bin/bash
cd "$(dirname "$0")/.."

set -e

docker compose run --rm web bundle install
