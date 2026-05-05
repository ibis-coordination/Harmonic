#!/bin/bash
#
# Check for direct Vote/Option mutation outside DecisionActionService.
#
# RULE: All Vote and Option create/save/update/destroy operations on decisions
# must go through DecisionActionService to ensure audit chain entries are recorded.
#
# Exceptions:
# - DecisionActionService itself (the chokepoint)
# - Test files (test setup creates records directly)
# - Lines marked with "# audit-safety-ignore" (with explanation)
#
# Usage:
#   ./scripts/check-audit-safety.sh           # Check all app files
#   ./scripts/check-audit-safety.sh --staged  # Check staged files only (for pre-commit)
#

set -e

cd "$(dirname "$0")/.."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Patterns to detect direct Vote/Option class-level mutations
# Matches: Vote.create, Vote.create!, Vote.new(...).save, Option.create!, etc.
CLASS_PATTERNS='(Vote|Option)\.(create[!]?|find_or_create_by[!]?)\b'

# Files that are allowed to mutate Vote/Option directly
ALLOWED_FILES=(
    "app/services/decision_action_service.rb"
    "app/services/api_helper.rb"
)

check_files() {
    local files="$1"
    local found=0

    echo -e "${CYAN}Checking for direct Vote/Option mutations outside DecisionActionService...${NC}"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$file" ]] && continue

        # Skip allowed files
        local skip=0
        for allowed in "${ALLOWED_FILES[@]}"; do
            if [[ "$file" == "$allowed" ]]; then
                skip=1
                break
            fi
        done
        [[ $skip -eq 1 ]] && continue

        # Skip test files
        if echo "$file" | grep -qE '^test/'; then
            continue
        fi

        # Check for Vote/Option class-level mutations
        while IFS=: read -r line_num line_content; do
            [[ -z "$line_num" ]] && continue

            # Skip comment-only lines
            if echo "$line_content" | grep -qE '^\s*#'; then
                continue
            fi

            # Skip lines with audit-safety-ignore
            if echo "$line_content" | grep -q "audit-safety-ignore"; then
                continue
            fi

            echo -e "${RED}Banned:${NC} $file:$line_num"
            echo "  $line_content"
            echo "  (Vote/Option mutations must go through DecisionActionService)"
            echo ""
            found=1

        done < <(grep -nE "$CLASS_PATTERNS" "$file" 2>/dev/null || true)

    done <<< "$files"

    return $found
}

#
# --staged: Check staged files only (for pre-commit hook)
#
if [[ "$1" == "--staged" ]]; then
    FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.rb$' | grep -E '^app/' || true)

    if [[ -z "$FILES" ]]; then
        echo -e "${GREEN}No Ruby files staged in app/.${NC}"
        exit 0
    fi

    if check_files "$FILES"; then
        echo -e "${GREEN}✓ No direct Vote/Option mutations found outside DecisionActionService.${NC}"
    else
        echo -e "${RED}✗ Direct Vote/Option mutations are banned outside DecisionActionService.${NC}"
        echo "  Use DecisionActionService.cast_vote!, .add_option!, .remove_option!, etc."
        echo "  If this is intentional, add '# audit-safety-ignore: <reason>' to the line."
        exit 1
    fi
    exit 0
fi

#
# Default: Check all app files
#
FILES=$(find app -name "*.rb" -type f | sort)

if check_files "$FILES"; then
    echo -e "${GREEN}✓ No direct Vote/Option mutations found outside DecisionActionService.${NC}"
else
    echo ""
    echo -e "${RED}All Vote/Option mutations must go through DecisionActionService:${NC}"
    echo "  - DecisionActionService.cast_vote!(decision:, vote:, actor:)"
    echo "  - DecisionActionService.add_option!(decision:, option:, actor:)"
    echo "  - DecisionActionService.remove_option!(decision:, option:, actor:)"
    echo "  - DecisionActionService.close_decision!(decision:, actor:)"
    echo ""
    echo "If this is intentional, add '# audit-safety-ignore: <reason>' to the line."
    exit 1
fi
