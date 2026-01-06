#!/bin/bash
#
# Check for debug code that shouldn't be committed.
# Detects: binding.pry, binding.irb, debugger, byebug, console.log, puts for debugging
#
# Usage:
#   ./scripts/check-debug-code.sh           # Check staged files (for pre-commit)
#   ./scripts/check-debug-code.sh --all     # Check all app files
#

set -e

cd "$(dirname "$0")/.."

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Debug patterns to detect (uncommented lines only)
# Ruby: binding.pry, binding.irb, byebug, debugger (but not debugger_controller)
# JS: console.log/debug/dir/trace, debugger statement
RUBY_PATTERNS='^[^#]*\b(binding\.pry|binding\.irb|byebug)\b|^[^#]*\bdebugger\b(?!.*controller)'
JS_PATTERNS='^[^/]*console\.(log|debug|dir|trace)\s*\(|^[^/]*\bdebugger\s*;'

#
# --all: Check entire codebase
#
if [[ "$1" == "--all" ]]; then
    echo -e "${CYAN}Scanning for debug code...${NC}"
    echo ""

    FOUND=0

    # Check Ruby files
    RUBY_MATCHES=$(grep -rn -E "$RUBY_PATTERNS" app/ lib/ test/ \
        --include="*.rb" 2>/dev/null || true)

    if [[ -n "$RUBY_MATCHES" ]]; then
        echo -e "${RED}Ruby debug code found:${NC}"
        echo "$RUBY_MATCHES" | while read -r line; do
            echo "  $line"
        done
        echo ""
        FOUND=1
    fi

    # Check JS files
    JS_MATCHES=$(grep -rn -E "$JS_PATTERNS" app/ \
        --include="*.js" 2>/dev/null || true)

    if [[ -n "$JS_MATCHES" ]]; then
        echo -e "${RED}JavaScript debug code found:${NC}"
        echo "$JS_MATCHES" | while read -r line; do
            echo "  $line"
        done
        echo ""
        FOUND=1
    fi

    if [[ "$FOUND" -eq 0 ]]; then
        echo -e "${GREEN}✓ No debug code found.${NC}"
    else
        echo -e "${YELLOW}Found debug code that may need removal before production.${NC}"
        exit 1
    fi
    exit 0
fi

#
# Default (pre-commit): Check staged files only
#
RUBY_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.rb$' || true)
JS_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.js$' || true)

if [[ -z "$RUBY_FILES" && -z "$JS_FILES" ]]; then
    exit 0  # No relevant files staged
fi

FOUND=0

# Check staged Ruby files
if [[ -n "$RUBY_FILES" ]]; then
    RUBY_MATCHES=$(echo "$RUBY_FILES" | xargs grep -n -E "$RUBY_PATTERNS" 2>/dev/null || true)

    if [[ -n "$RUBY_MATCHES" ]]; then
        echo -e "${RED}✗ Debug code found in staged Ruby files:${NC}"
        echo ""
        echo "$RUBY_MATCHES" | while read -r line; do
            echo "  $line"
        done
        echo ""
        FOUND=1
    fi
fi

# Check staged JS files
if [[ -n "$JS_FILES" ]]; then
    JS_MATCHES=$(echo "$JS_FILES" | xargs grep -n -E "$JS_PATTERNS" 2>/dev/null || true)

    if [[ -n "$JS_MATCHES" ]]; then
        echo -e "${RED}✗ Debug code found in staged JavaScript files:${NC}"
        echo ""
        echo "$JS_MATCHES" | while read -r line; do
            echo "  $line"
        done
        echo ""
        FOUND=1
    fi
fi

if [[ "$FOUND" -eq 1 ]]; then
    echo -e "${YELLOW}Please remove debug code before committing.${NC}"
    echo "To skip this check: git commit --no-verify"
    exit 1
fi

exit 0
