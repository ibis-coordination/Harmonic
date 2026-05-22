#!/bin/bash
# Print a snapshot of the current machine's resource usage.
# Read-only — performs no cleanup. Run scripts/cleanup.sh to reclaim Docker space.
#
# Usage:
#   ./scripts/resources.sh

set -e
cd "$(dirname "$0")/.."

OS="$(uname)"

echo "=== Disk ==="
df -h /
echo ""

echo "=== Docker ==="
docker system df
echo ""

echo "=== Memory ==="
if [ "$OS" = "Darwin" ]; then
  top -l 1 -s 0 | grep -E '^(PhysMem|VM)'
else
  free -h
fi
echo ""

echo "=== Load ==="
uptime
echo ""

echo "=== Top processes by memory ==="
if [ "$OS" = "Darwin" ]; then
  ps -Ao pid,user,%mem,%cpu,comm -m | head -n 11
else
  ps -eo pid,user,%mem,%cpu,comm --sort=-%mem | head -n 11
fi
echo ""

echo "To reclaim Docker space (stopped containers, dangling images, build cache):"
echo "  ./scripts/cleanup.sh"
