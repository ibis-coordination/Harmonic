#!/bin/bash
#
# Check if TODO_INDEX.md is in sync with actual TODOs in the codebase.
#
# Usage:
#   ./scripts/check-todo-index.sh           # Check staged files (for pre-commit hook)
#   ./scripts/check-todo-index.sh --all     # Compare index count vs actual count
#   ./scripts/check-todo-index.sh --list    # List all TODOs with file:line and content
#

set -e

cd "$(dirname "$0")/.."

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

TODO_INDEX="docs/TODO_INDEX.md"

#
# --list: Show all TODOs in the codebase
#
if [[ "$1" == "--list" ]]; then
    echo -e "${CYAN}All TODOs in codebase:${NC}"
    echo ""
    grep -rn "# TODO\|// TODO\|<!-- TODO" app/ \
        --include="*.rb" \
        --include="*.js" \
        --include="*.erb" \
        2>/dev/null | while read -r line; do
        FILE=$(echo "$line" | cut -d: -f1)
        LINE_NUM=$(echo "$line" | cut -d: -f2)
        CONTENT=$(echo "$line" | cut -d: -f3- | sed 's/^[[:space:]]*//')
        echo -e "${GREEN}$FILE:$LINE_NUM${NC}"
        echo "  $CONTENT"
        echo ""
    done

    TOTAL=$(grep -rn "# TODO\|// TODO\|<!-- TODO" app/ \
        --include="*.rb" --include="*.js" --include="*.erb" 2>/dev/null | wc -l | tr -d ' ')
    echo -e "${CYAN}Total: $TOTAL TODOs${NC}"
    exit 0
fi

#
# --all: Check if index is in sync with codebase
#
if [[ "$1" == "--all" ]]; then
    echo -e "${CYAN}Checking TODO_INDEX.md sync status...${NC}"
    echo ""

    # Count TODOs in code
    CODE_COUNT=$(grep -rn "# TODO\|// TODO\|<!-- TODO" app/ \
        --include="*.rb" --include="*.js" --include="*.erb" 2>/dev/null | wc -l | tr -d ' ')

    # Get count from index header
    if [[ -f "$TODO_INDEX" ]]; then
        INDEX_TOTAL=$(grep -oE 'Total TODOs.*[0-9]+' "$TODO_INDEX" | grep -oE '[0-9]+' | head -1 || echo "?")

        echo "TODOs in codebase:     $CODE_COUNT"
        echo "Documented in index:   $INDEX_TOTAL"
        echo ""

        if [[ "$CODE_COUNT" != "$INDEX_TOTAL" ]]; then
            echo -e "${YELLOW}⚠️  Count mismatch! Index may be out of date.${NC}"
            echo ""
            echo "Files with TODOs:"
            grep -rn "# TODO\|// TODO\|<!-- TODO" app/ \
                --include="*.rb" --include="*.js" --include="*.erb" 2>/dev/null \
                | cut -d: -f1 | sort | uniq -c | sort -rn
            echo ""
            echo -e "Run ${CYAN}./scripts/check-todo-index.sh --list${NC} to see all TODOs with content"
        else
            echo -e "${GREEN}✓ TODO count matches. Index appears up to date.${NC}"
        fi
    else
        echo -e "${RED}✗ $TODO_INDEX not found${NC}"
        exit 1
    fi
    exit 0
fi

#
# Default (pre-commit): Check if staged files have TODO changes
#
FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.(rb|js|erb)$' || true)

if [[ -z "$FILES" ]]; then
    exit 0  # Silent exit when no relevant files staged
fi

TODO_CHANGES=$(echo "$FILES" | xargs git diff --cached 2>/dev/null | grep -E "^[+-].*(# TODO|// TODO|<!-- TODO)" || true)

if [[ -n "$TODO_CHANGES" ]]; then
    echo -e "${YELLOW}⚠️  TODO comments changed in this commit:${NC}"
    echo ""
    echo "$TODO_CHANGES" | while read -r line; do
        if [[ "$line" == +* ]]; then
            echo -e "  ${GREEN}$line${NC}"
        else
            echo -e "  ${RED}$line${NC}"
        fi
    done
    echo ""

    if git diff --cached --name-only | grep -q "$TODO_INDEX"; then
        echo -e "${GREEN}✓ $TODO_INDEX is being updated in this commit.${NC}"
    else
        echo -e "${YELLOW}Remember to update $TODO_INDEX${NC}"
        echo ""
        echo "  ./scripts/check-todo-index.sh --list   # See all TODOs"
        echo "  ./scripts/check-todo-index.sh --all    # Check sync status"
        echo ""
        echo "To skip: git commit --no-verify"
    fi
fi

exit 0
