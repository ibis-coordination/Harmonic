#!/bin/bash
#
# Enforce that the audit-immutability trigger is never disabled outside of
# Rails migrations (or test files that forge tampering to validate detection).
#
# RULE: The PostgreSQL trigger `enforce_audit_entry_immutability` blocks
# updates to decision_audit_entries — that's the load-bearing claim behind
# audit chain integrity. The only legitimate caller of `DISABLE TRIGGER` /
# `ENABLE TRIGGER` against this trigger is a one-shot data migration in
# `db/migrate/`. Tests under `test/` may also bypass it to forge corrupted
# entries that exercise the verifier's detection logic.
#
# Anywhere else (app/, lib/, scripts/, jobs/, services/, etc.) is a regression
# and must be rejected at commit time.
#
# Usage:
#   ./scripts/check-audit-immutability.sh           # Check all source files
#   ./scripts/check-audit-immutability.sh --staged  # Check staged files only
#

cd "$(dirname "$0")/.." || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Match either DISABLE or ENABLE of the audit-immutability trigger.
PATTERN='(DISABLE|ENABLE) TRIGGER[[:space:]]+enforce_audit_entry_immutability'

# Allowlist of paths that may legitimately reference the toggle:
#   - db/migrate/* — the one-shot data migration that rehashes v1 → v2
#   - db/structure.sql — schema dump (defines the trigger; never toggles it)
#   - test/* — tampering tests that forge corrupted entries
#   - this script itself (contains the pattern in comments and the grep call)
ALLOWED_REGEX='^(db/migrate/|db/structure\.sql$|test/|scripts/check-audit-immutability\.sh$)'

violations=$(
    if [[ "$1" == "--staged" ]]; then
        FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
        if [[ -z "$FILES" ]]; then
            exit 0
        fi
        # Filter to files that exist (not deleted) and grep each
        echo "$FILES" | while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            echo "$f" | grep -qE "$ALLOWED_REGEX" && continue
            grep -nHE "$PATTERN" "$f" 2>/dev/null
        done
    else
        find . -type f \
            \( -name "*.rb" -o -name "*.sh" -o -name "*.sql" -o -name "*.erb" \) \
            -not -path "./node_modules/*" \
            -not -path "./.git/*" \
            -not -path "./vendor/*" \
            -not -path "./tmp/*" \
            -not -path "./log/*" \
            -not -path "./app/assets/builds/*" \
            -print0 \
            | xargs -0 grep -nHE "$PATTERN" 2>/dev/null \
            | sed 's|^\./||' \
            | grep -vE "$ALLOWED_REGEX"
    fi
)

echo -e "${CYAN}Checking for audit-immutability trigger toggles outside db/migrate/...${NC}"
echo ""

if [[ -z "$violations" ]]; then
    echo -e "${GREEN}✓ No audit-immutability trigger toggles outside db/migrate/.${NC}"
    exit 0
fi

echo -e "${RED}Banned references found:${NC}"
echo "$violations" | sed 's/^/  /'
echo ""
echo -e "${RED}✗ Toggling the audit-immutability trigger is only permitted inside db/migrate/.${NC}"
echo "  The trigger guarantees decision_audit_entries are immutable. Bypassing it"
echo "  outside a one-shot migration would silently undermine the audit chain."
echo "  If you genuinely need a new data migration that rehashes entries, add it"
echo "  to db/migrate/ — not to app/, lib/, or scripts/."
exit 1
