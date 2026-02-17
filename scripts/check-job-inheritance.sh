#!/bin/bash
#
# Check that all Sidekiq jobs inherit from TenantScopedJob or SystemJob.
#
# RULE: Jobs must inherit from one of:
#   - TenantScopedJob - For jobs that operate within a tenant context
#   - SystemJob       - For jobs that operate across tenants (maintenance, cleanup)
#
# Direct inheritance from ApplicationJob is BANNED because it bypasses
# tenant context enforcement.
#
# Exceptions:
#   - TenantScopedJob and SystemJob themselves (which extend ApplicationJob)
#   - ApplicationJob itself (the base class)
#
# Usage:
#   ./scripts/check-job-inheritance.sh           # Check all job files
#   ./scripts/check-job-inheritance.sh --staged  # Check staged files only (for pre-commit)
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

    echo -e "${CYAN}Checking job inheritance...${NC}"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$file" ]] && continue

        # Skip the base classes themselves
        local basename=$(basename "$file")
        if [[ "$basename" == "application_job.rb" ]] || \
           [[ "$basename" == "tenant_scoped_job.rb" ]] || \
           [[ "$basename" == "system_job.rb" ]]; then
            continue
        fi

        # Check for jobs inheriting from ApplicationJob directly
        while IFS=: read -r line_num line_content; do
            [[ -z "$line_num" ]] && continue

            # Skip comment-only lines
            if echo "$line_content" | grep -qE '^\s*#'; then
                continue
            fi

            # Skip if line has job-inheritance-allowed comment
            if echo "$line_content" | grep -q "# job-inheritance-allowed"; then
                continue
            fi

            echo -e "${RED}Banned:${NC} $file:$line_num"
            echo "  $line_content"
            echo ""
            echo "  Jobs must inherit from TenantScopedJob or SystemJob, not ApplicationJob."
            echo ""
            found=1

        done < <(grep -n "< ApplicationJob" "$file" 2>/dev/null || true)

    done <<< "$files"

    return $found
}

#
# --staged: Check staged files only (for pre-commit hook)
#
if [[ "$1" == "--staged" ]]; then
    FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.rb$' | grep -E '^app/jobs/' || true)

    if [[ -z "$FILES" ]]; then
        echo -e "${GREEN}No job files staged in app/jobs/.${NC}"
        exit 0
    fi

    if check_files "$FILES"; then
        echo -e "${GREEN}✓ All jobs properly inherit from TenantScopedJob or SystemJob.${NC}"
    else
        echo -e "${RED}✗ Jobs must inherit from TenantScopedJob or SystemJob.${NC}"
        echo ""
        echo "  TenantScopedJob: For jobs operating within a tenant context"
        echo "  SystemJob:       For cross-tenant maintenance/cleanup jobs"
        exit 1
    fi
    exit 0
fi

#
# Default: Check all job files
#
FILES=$(find app/jobs -name "*.rb" -type f | sort)

if check_files "$FILES"; then
    echo -e "${GREEN}✓ All jobs properly inherit from TenantScopedJob or SystemJob.${NC}"
else
    echo ""
    echo -e "${RED}Jobs must inherit from TenantScopedJob or SystemJob:${NC}"
    echo ""
    echo "  TenantScopedJob: For jobs that operate within a tenant context."
    echo "                   Use set_tenant_context!(tenant) before accessing scoped data."
    echo ""
    echo "  SystemJob:       For cross-tenant maintenance/cleanup jobs."
    echo "                   Use unscoped_for_system_job to access data across tenants."
    echo ""
    exit 1
fi
