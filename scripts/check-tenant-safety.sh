#!/bin/bash
#
# Check for unsafe use of .unscoped in the codebase.
#
# RULE: Direct .unscoped calls are banned. Use one of the safe alternatives:
#
#   - .tenant_scoped_only(tenant_id)  - Cross-superagent access within a tenant
#   - .unscoped_for_admin(user)       - Cross-tenant access for app/system admins
#   - .unscoped_for_system_job        - Cross-tenant access for background jobs
#
# These methods provide runtime checks to prevent accidental cross-tenant leaks.
#
# For models without tenant scoping (User, Tenant), don't use .unscoped at all -
# they have no default scope to bypass.
#
# Exceptions:
# - Lines marked with "# unscoped-allowed" (only in ApplicationRecord definitions)
#
# Usage:
#   ./scripts/check-tenant-safety.sh           # Check all app files
#   ./scripts/check-tenant-safety.sh --staged  # Check staged files only (for pre-commit)
#

set -e

cd "$(dirname "$0")/.."

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

check_files() {
    local files="$1"
    local found=0

    echo -e "${CYAN}Checking for banned .unscoped usage...${NC}"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$file" ]] && continue

        # Find lines with .unscoped method calls (e.g., Model.unscoped, .unscoped.where)
        # We look for the pattern: word.unscoped followed by word boundary (not alphanumeric)
        while IFS=: read -r line_num line_content; do
            [[ -z "$line_num" ]] && continue

            # Skip comment-only lines
            if echo "$line_content" | grep -qE '^\s*#'; then
                continue
            fi

            # Skip if line has unscoped-allowed comment
            if echo "$line_content" | grep -q "# unscoped-allowed"; then
                continue
            fi

            # Skip if using safe alternatives (.unscoped_for_admin or .unscoped_for_system_job)
            if echo "$line_content" | grep -qE "\.unscoped_for_admin|\.unscoped_for_system_job"; then
                continue
            fi

            # Skip if defining the safe methods (def self.unscoped_for_)
            if echo "$line_content" | grep -qE "def self\.unscoped_for_"; then
                continue
            fi

            echo -e "${RED}Banned:${NC} $file:$line_num"
            echo "  $line_content"
            echo ""
            found=1

        done < <(grep -n "\.unscoped[^_]" "$file" 2>/dev/null || true)

    done <<< "$files"

    # Check for find_by_sql
    echo -e "${CYAN}Checking find_by_sql usage...${NC}"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$file" ]] && continue

        while IFS=: read -r line_num line_content; do
            [[ -z "$line_num" ]] && continue

            # Skip if line has tenant-safe comment
            if echo "$line_content" | grep -q "# tenant-safe"; then
                continue
            fi

            # find_by_sql always needs manual review
            echo -e "${YELLOW}Manual review needed:${NC} $file:$line_num"
            echo "  $line_content"
            echo "  (find_by_sql bypasses default_scope - ensure tenant filtering in SQL)"
            echo ""

        done < <(grep -n "find_by_sql" "$file" 2>/dev/null || true)

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
        echo -e "${GREEN}✓ No banned .unscoped usage found.${NC}"
    else
        echo -e "${RED}✗ .unscoped is banned. Use a safe alternative:${NC}"
        echo "  - .tenant_scoped_only(tenant_id) for cross-superagent access"
        echo "  - .unscoped_for_admin(user) for admin operations"
        echo "  - .unscoped_for_system_job for background jobs"
        exit 1
    fi
    exit 0
fi

#
# Default: Check all app files
#
FILES=$(find app -name "*.rb" -type f | sort)

if check_files "$FILES"; then
    echo -e "${GREEN}✓ No banned .unscoped usage found.${NC}"
else
    echo ""
    echo -e "${RED}Replace .unscoped with a safe alternative:${NC}"
    echo "  - .tenant_scoped_only(tenant_id) for cross-superagent access within a tenant"
    echo "  - .unscoped_for_admin(current_user) for admin operations"
    echo "  - .unscoped_for_system_job for background maintenance jobs"
    echo ""
    echo "For User/Tenant models, remove .unscoped entirely (they have no default scope)."
    exit 1
fi
