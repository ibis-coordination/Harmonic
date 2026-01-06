#!/bin/bash
#
# Regenerate docs/TODO_INDEX.md from source code
#
# Usage: ./scripts/generate-todo-index.sh
#

set -e

cd "$(dirname "$0")/.."

TODO_INDEX="docs/TODO_INDEX.md"
TEMP_FILE=$(mktemp)

echo "Scanning for TODOs..."

# Get all TODOs with context
grep -rn "# TODO\|// TODO\|<!-- TODO" app/ \
    --include="*.rb" \
    --include="*.js" \
    --include="*.erb" \
    2>/dev/null | sort > "$TEMP_FILE"

TODO_COUNT=$(wc -l < "$TEMP_FILE" | tr -d ' ')

echo "Found $TODO_COUNT TODOs"
echo ""
echo "TODOs by file:"
echo "$TEMP_FILE" | cut -d: -f1 | sort | uniq -c | sort -rn
echo ""
echo "Raw TODO list saved to: $TEMP_FILE"
echo ""
echo "To view: cat $TEMP_FILE"
echo ""
echo "Note: Manual categorization is required to update $TODO_INDEX"
echo "The automated scan provides the raw data; organize by category in the markdown file."
