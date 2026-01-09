#!/bin/bash
#
# Scan for accidentally committed secrets, API keys, and credentials.
#
# Usage:
#   ./scripts/check-secrets.sh           # Check staged files (for pre-commit)
#   ./scripts/check-secrets.sh --all     # Scan entire codebase
#

set -e

cd "$(dirname "$0")/.."

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Files/patterns to exclude from scanning (dev configs, tests, this script)
EXCLUDE_FILES=".env.example|check-secrets.sh|secrets.*test|fixtures|database.yml|importmap.rb"

# Patterns that suggest secrets (high confidence)
# These patterns look for actual values, not just variable names
SECRET_PATTERNS=(
    # API keys with actual values (not empty assignments)
    '[A-Za-z_]*API[_-]?KEY["\s]*[:=]["\s]*[A-Za-z0-9]{16,}'
    '[A-Za-z_]*API[_-]?TOKEN["\s]*[:=]["\s]*[A-Za-z0-9]{16,}'
    '[A-Za-z_]*SECRET[_-]?KEY["\s]*[:=]["\s]*[A-Za-z0-9]{16,}'

    # AWS credentials
    'AKIA[0-9A-Z]{16}'
    'aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}'

    # GitHub tokens
    'ghp_[A-Za-z0-9]{36}'
    'github_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{59}'
    'gho_[A-Za-z0-9]{36}'
    'ghu_[A-Za-z0-9]{36}'
    'ghs_[A-Za-z0-9]{36}'
    'ghr_[A-Za-z0-9]{36}'

    # Private keys
    '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'
    '-----BEGIN PGP PRIVATE KEY BLOCK-----'

    # Generic secrets with values
    'password\s*[:=]\s*["\x27][^"\x27]{8,}["\x27]'

    # Slack tokens
    'xox[baprs]-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}'

    # Stripe keys
    'sk_live_[0-9a-zA-Z]{24}'
    'rk_live_[0-9a-zA-Z]{24}'
    'pk_live_[0-9a-zA-Z]{24}'

    # Anthropic API keys
    'sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{80,}'

    # OpenAI API keys
    'sk-[A-Za-z0-9]{48}'
    'sk-proj-[A-Za-z0-9_-]{48,}'

    # Google API keys and service accounts
    'AIza[0-9A-Za-z_-]{35}'
    '"type"\s*:\s*"service_account"'

    # Heroku API key
    '[hH][eE][rR][oO][kK][uU].*[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'

    # Twilio
    'SK[a-f0-9]{32}'
    'AC[a-f0-9]{32}'

    # SendGrid
    'SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}'

    # Mailchimp
    '[a-f0-9]{32}-us[0-9]{1,2}'

    # NPM tokens
    'npm_[A-Za-z0-9]{36}'

    # PyPI tokens
    'pypi-[A-Za-z0-9_-]{50,}'

    # Generic hex tokens (40+ chars, commonly used for API tokens)
    '["\x27][a-f0-9]{40,}["\x27]'

    # Base64 encoded secrets (long base64 strings assigned to secret-like variables)
    '(SECRET|TOKEN|KEY|PASS)[A-Z_]*["\s]*[:=]["\s]*[A-Za-z0-9+/]{40,}={0,2}'

    # Database URLs with credentials
    '(mysql|postgres|postgresql|mongodb|redis)://[^:]+:[^@]+@'

    # JWT tokens (they're long base64 strings with dots)
    'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*'

    # Bearer tokens in code
    '[Bb]earer\s+[A-Za-z0-9_-]{20,}'

    # Basic auth in URLs (user:pass must come before first slash, not in path)
    'https?://[^/:]+:[^/@]+@[^/]+'
)

# Build combined pattern
COMBINED_PATTERN=$(IFS='|'; echo "${SECRET_PATTERNS[*]}")

scan_files() {
    local files="$1"

    if [[ -z "$files" ]]; then
        return 1  # No matches (return 1 = false in bash conditional)
    fi

    MATCHES=$(echo "$files" | xargs grep -E -n "$COMBINED_PATTERN" 2>/dev/null | grep -v -E "$EXCLUDE_FILES" || true)

    if [[ -n "$MATCHES" ]]; then
        echo -e "${RED}Potential secrets found:${NC}"
        echo ""
        echo "$MATCHES" | while read -r line; do
            # Truncate long lines to avoid showing full secrets
            truncated=$(echo "$line" | cut -c1-120)
            if [[ ${#line} -gt 120 ]]; then
                truncated="${truncated}..."
            fi
            echo "  $truncated"
        done
        echo ""
        return 0  # Found matches (return 0 = true in bash conditional)
    fi

    return 1  # No matches
}

#
# --all: Scan entire codebase
#
if [[ "$1" == "--all" ]]; then
    echo -e "${CYAN}Scanning for secrets...${NC}"
    echo ""

    # Get all text files, excluding common non-code files
    FILES=$(find . -type f \( \
        -name "*.rb" -o \
        -name "*.js" -o \
        -name "*.ts" -o \
        -name "*.yml" -o \
        -name "*.yaml" -o \
        -name "*.json" -o \
        -name "*.env" -o \
        -name "*.env.*" -o \
        -name "*.sh" -o \
        -name "*.erb" -o \
        -name "*.rake" -o \
        -name "*.py" -o \
        -name "*.ipynb" -o \
        -name "*.md" -o \
        -name "*.sql" -o \
        -name "*.toml" -o \
        -name "*.cfg" -o \
        -name "*.conf" -o \
        -name "*.ini" -o \
        -name "Dockerfile" -o \
        -name "docker-compose*.yml" -o \
        -name "Gemfile" -o \
        -name ".env*" \
    \) \
        ! -path "./.git/*" \
        ! -path "./node_modules/*" \
        ! -path "./vendor/*" \
        ! -path "./tmp/*" \
        ! -path "./log/*" \
        ! -name "*.example" \
        2>/dev/null)

    if scan_files "$FILES"; then
        echo -e "${YELLOW}⚠️  Review the above for potential secrets.${NC}"
        echo "False positives are possible - review each match carefully."
        exit 1
    else
        echo -e "${GREEN}✓ No obvious secrets found.${NC}"
    fi
    exit 0
fi

#
# Default (pre-commit): Check staged files only
#
FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.(rb|js|ts|yml|yaml|json|env|sh|erb|rake|py|ipynb|md|sql|toml|cfg|conf|ini)$|Dockerfile|Gemfile|docker-compose' | grep -v -E "$EXCLUDE_FILES" || true)

if [[ -z "$FILES" ]]; then
    exit 0  # No relevant files staged
fi

if scan_files "$FILES"; then
    echo -e "${RED}✗ Potential secrets detected in staged files!${NC}"
    echo ""
    echo "If these are false positives, you can:"
    echo "  1. Use environment variables instead of hardcoded values"
    echo "  2. Add the pattern to EXCLUDE_FILES in this script"
    echo "  3. Skip with: git commit --no-verify"
    exit 1
fi

exit 0
