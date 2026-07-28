#!/bin/bash
#
# Check user-facing copy against docs/CONTROLLED_VOCABULARY.md.
#
# RULES (the mechanically checkable subset of the controlled vocabulary):
#   1. Visibility values are "tiers" — never "visibility zones" or "levels of
#      visibility".
#   2. "the public space" is singular and is the only approved name for the
#      per-subdomain public area — "public spaces", "main space",
#      "members-only space", and "the main collective" are banned in copy.
#   3. User-facing copy says "subdomain", not "tenant".
#   4. An agent's accountable user is their "principal", never their "owner";
#      a chat is not "a private chat", a "direct message", or a "DM".
#   5. "primary list", "user list", and "persona" are internal terms, never copy.
#   6. Stored funds are the "prepaid balance", never "credits".
#   7. Spend controls are "caps" (per-agent) and "ceilings" (pool draws) —
#      never "spend limits" or "quotas". Frequency bounds are "rate limits".
#   8. Users have a "handle", never a "username" (external providers' own
#      usernames are the exception — mark those vocab-ok).
#
# Scope:
#   - View templates (app/views/**/*.erb): prose outside ERB tags. ERB code
#     and comment regions (<% ... %>) are stripped before matching, so code
#     identifiers and template comments never trigger the check.
#   - Copy strings in app/controllers, app/services, and app/helpers:
#     double-quoted string literals on non-comment lines. Skipped: `raise`
#     lines (developer-facing invariants), logger lines, #{interpolations},
#     and app/controllers/api/app_admin/ (exempt Admin App JSON API).
#
# Exceptions: lines containing "vocab-ok" (in a comment on the same line).
#
# Usage:
#   ./scripts/check-vocabulary.sh           # Check all in-scope files
#   ./scripts/check-vocabulary.sh --staged  # Check staged files only
#

set -e

cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

found=0

# Banned patterns in rendered prose (case-insensitive).
PROSE_PATTERN='visibility (zone|level)|levels of visibility|\bpublic spaces\b|\bmain space\b|\bmembers-only space\b|\bmain collective\b|\btenants?\b|\bprivate chats?\b|agent'"'"'?s owner|owner of this (ai_)?agent|\bprimary list\b|\buser list\b|\bpersonas?\b|\busernames?\b|spend(ing)? limits?|\bquotas?\b|direct messages?|\bDMs?\b|prepaid credits?|credit balance|\bcredits\b|trustee grants?'

# Strip ERB regions (<% ... %>, including <%= and <%#) while preserving line
# numbers, so grep line numbers refer to the original file.
strip_erb() {
    perl -0777 -pe 's{<%.*?%>}{ my $m = $&; $m =~ s/[^\n]//g; $m }ges' "$1"
}

check_view_file() {
    local file="$1"
    local waived
    waived=$(grep -n 'vocab-ok' "$file" | cut -d: -f1)

    while IFS=: read -r line_num line_content; do
        [[ -z "$line_num" ]] && continue
        if echo "$waived" | grep -qx "$line_num"; then
            continue
        fi
        echo -e "${RED}✗ $file:$line_num${NC}"
        echo "    $(echo "$line_content" | sed 's/^[[:space:]]*//' | cut -c1-160)"
        found=1
    done < <(strip_erb "$file" | grep -inE "$PROSE_PATTERN" || true)
}

check_ruby_file() {
    local file="$1"

    while IFS=: read -r line_num line_content; do
        [[ -z "$line_num" ]] && continue
        echo -e "${RED}✗ $file:$line_num${NC}"
        echo "    $(echo "$line_content" | sed 's/^[[:space:]]*//' | cut -c1-160)"
        found=1
    done < <(grep -nE '"[^"]*"' "$file" \
        | grep -viE '^[0-9]+:\s*#' \
        | grep -vE '\braise\b|vocab-ok|logger\.|"[a-z_]+" *=>' \
        | sed 's/#{[^}]*}//g' \
        | grep -iE '"[^"]*('"$PROSE_PATTERN"')[^"]*"' || true)
}

echo -e "${CYAN}Checking user-facing copy against the controlled vocabulary...${NC}"
echo ""

if [[ "$1" == "--staged" ]]; then
    view_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '^app/views/.*\.erb$' || true)
    ruby_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '^app/(controllers|services|helpers)/.*\.rb$' | grep -v '^app/controllers/api/app_admin/' || true)
else
    view_files=$(find app/views -name '*.erb')
    ruby_files=$(find app/controllers app/services app/helpers -name '*.rb' | grep -v '^app/controllers/api/app_admin/')
fi

for f in $view_files; do
    [[ -f "$f" ]] && check_view_file "$f"
done
for f in $ruby_files; do
    [[ -f "$f" ]] && check_ruby_file "$f"
done

if [[ $found -eq 1 ]]; then
    echo ""
    echo -e "${RED}Controlled-vocabulary violations found.${NC}"
    echo "See docs/CONTROLLED_VOCABULARY.md for the approved terms."
    echo "For a legitimate exception, mark the line with a 'vocab-ok' comment."
    exit 1
fi

echo -e "${GREEN}✓ No controlled-vocabulary violations found.${NC}"
