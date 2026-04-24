#!/bin/bash
#
# Check for style guide violations in Pulse CSS files.
#
# RULES:
# 1. No hardcoded colors in pulse/ CSS files — use --color-* variables from root_variables.css
#    (box-shadow rgba values are allowed since shadows aren't design tokens)
# 2. New class names in pulse/ CSS files should use the pulse- prefix
#
# Exceptions:
# - Lines marked with "/* styleguide-ok */"
# - Color values inside CSS variable declarations (--color-*)
# - rgba() inside box-shadow declarations
#
# Usage:
#   ./scripts/check-style-guide.sh           # Check all pulse CSS files (hardcoded colors only)
#   ./scripts/check-style-guide.sh --staged  # Check staged files (colors + new class prefix)
#   ./scripts/check-style-guide.sh --diff <base>  # Check diff from base branch (colors + new class prefix)
#

set -e

cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PULSE_DIR="app/assets/stylesheets/pulse"
found=0

check_hardcoded_colors() {
    local file="$1"

    while IFS=: read -r line_num line_content; do
        [[ -z "$line_num" ]] && continue

        # Skip comments
        if echo "$line_content" | grep -qE '^\s*/?\*'; then
            continue
        fi

        # Skip lines with styleguide-ok marker
        if echo "$line_content" | grep -q 'styleguide-ok'; then
            continue
        fi

        # Skip CSS variable definitions (these ARE the token definitions)
        if echo "$line_content" | grep -qE '^\s*--color-'; then
            continue
        fi

        # Skip box-shadow declarations (rgba in shadows is acceptable)
        if echo "$line_content" | grep -qE 'box-shadow:'; then
            continue
        fi

        echo -e "${RED}Hardcoded color:${NC} $file:$line_num"
        echo "  $line_content"
        echo "  Use a --color-* variable from root_variables.css instead."
        echo ""
        found=1

    done < <(grep -n -E '#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(' "$file" 2>/dev/null || true)
}

# Check added lines in a diff for non-prefixed class names
check_diff_prefix() {
    local diff_output="$1"
    local file="$2"

    added_classes=$(echo "$diff_output" | grep -E '^\+\s*\.[a-z]' | grep -v '^\+\+\+' | grep -v '\.pulse-' || true)
    if [[ -n "$added_classes" ]]; then
        while IFS= read -r line; do
            line="${line#+}"  # strip leading +
            # Skip if styleguide-ok
            if echo "$line" | grep -q 'styleguide-ok'; then
                continue
            fi
            echo -e "${RED}Missing pulse- prefix (new class):${NC} $file"
            echo "  $line"
            echo "  New class names in pulse/ CSS should use the pulse- prefix."
            echo ""
            found=1
        done <<< "$added_classes"
    fi
}

if [[ "$1" == "--staged" ]]; then
    FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E "^${PULSE_DIR}/.*\.css$" || true)

    if [[ -z "$FILES" ]]; then
        exit 0
    fi

    echo -e "${CYAN}Checking staged Pulse CSS files for style guide violations...${NC}"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$file" ]] && continue
        check_hardcoded_colors "$file"
        check_diff_prefix "$(git diff --cached -U0 "$file" 2>/dev/null)" "$file"
    done <<< "$FILES"

elif [[ "$1" == "--diff" ]]; then
    BASE="${2:-main}"
    FILES=$(git diff "$BASE"...HEAD --name-only --diff-filter=ACM 2>/dev/null | grep -E "^${PULSE_DIR}/.*\.css$" || true)

    if [[ -z "$FILES" ]]; then
        echo -e "${GREEN}No Pulse CSS files changed since ${BASE}.${NC}"
        exit 0
    fi

    echo -e "${CYAN}Checking Pulse CSS changes since ${BASE} for style guide violations...${NC}"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$file" ]] && continue
        check_hardcoded_colors "$file"
        check_diff_prefix "$(git diff "$BASE"...HEAD -U0 -- "$file" 2>/dev/null)" "$file"
    done <<< "$FILES"

else
    FILES=$(find "$PULSE_DIR" -name "*.css" -type f 2>/dev/null | sort)

    if [[ -z "$FILES" ]]; then
        echo -e "${GREEN}No Pulse CSS files found.${NC}"
        exit 0
    fi

    echo -e "${CYAN}Checking Pulse CSS files for style guide violations...${NC}"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        check_hardcoded_colors "$file"
    done <<< "$FILES"
fi

if [[ $found -eq 0 ]]; then
    echo -e "${GREEN}✓ No style guide violations found.${NC}"
else
    echo -e "${RED}✗ Style guide violations found. See docs/STYLE_GUIDE.md for guidelines.${NC}"
    echo "  View the live style guide at /dev/styleguide (development only)."
    exit 1
fi
