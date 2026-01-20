#!/bin/bash
#
# Set up git hooks for this repository
#
# Usage: ./scripts/setup-hooks.sh
#

set -e

cd "$(dirname "$0")/.."

HOOKS_DIR=".git/hooks"
SCRIPTS_HOOKS_DIR="scripts/hooks"

echo "Setting up git hooks..."

# Copy pre-commit hook
if [[ -f "$SCRIPTS_HOOKS_DIR/pre-commit" ]]; then
    cp "$SCRIPTS_HOOKS_DIR/pre-commit" "$HOOKS_DIR/pre-commit"
    chmod +x "$HOOKS_DIR/pre-commit"
    echo "✓ Installed pre-commit hook"
fi

# Make check scripts executable
chmod +x scripts/check-todo-index.sh 2>/dev/null || true
chmod +x scripts/generate-todo-index.sh 2>/dev/null || true
chmod +x scripts/check-debug-code.sh 2>/dev/null || true
chmod +x scripts/check-secrets.sh 2>/dev/null || true

echo ""
echo "Git hooks installed successfully!"
echo ""
echo "Hooks will:"
echo "  - Block commits containing potential secrets/API keys"
echo "  - Block commits containing debug code (binding.pry, console.log, etc.)"
echo "  - Run Sorbet type checking"
echo "  - Run TypeScript type checking (V1 legacy)"
echo "  - Run V2 React client lint-staged (ESLint with functional programming rules)"
echo "  - Warn when TODO comments are added/removed without updating docs/TODO_INDEX.md"
echo ""
echo "To bypass hooks: git commit --no-verify"
