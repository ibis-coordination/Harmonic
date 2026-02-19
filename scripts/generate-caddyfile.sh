#!/bin/bash
# Generate Caddyfile from tenant subdomains in database
# Usage: ./scripts/generate-caddyfile.sh [--dry-run]
#
# This script is idempotent - safe to run anytime (e.g., after adding a tenant).
# It queries the database for all tenant subdomains and generates a Caddyfile.

set -e
cd "$(dirname "$0")/.."

CADDYFILE="Caddyfile"
CADDYFILE_GENERATED="Caddyfile.generated"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

# Detect environment and set compose file
detect_environment() {
    RAILS_ENV_FROM_ENV=$(grep -E "^RAILS_ENV=" .env 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || true)

    if [ "$RAILS_ENV" = "production" ] || [ "$RAILS_ENV_FROM_ENV" = "production" ]; then
        COMPOSE_FILE="docker-compose.production.yml"
        ENVIRONMENT="production"
    else
        COMPOSE_FILE="docker-compose.yml"
        ENVIRONMENT="development"
    fi
}

get_caddy_container() {
    docker compose -f "$COMPOSE_FILE" ps -q caddy 2>/dev/null || true
}

get_web_container() {
    docker compose -f "$COMPOSE_FILE" ps -q web 2>/dev/null || true
}

generate_caddyfile() {
    echo -e "${CYAN}Generating Caddyfile from database...${NC}"
    echo "Environment: $ENVIRONMENT"
    echo ""

    # Check web container is running
    WEB_CONTAINER=$(get_web_container)
    if [ -z "$WEB_CONTAINER" ]; then
        echo -e "${RED}Error: Web container not running. Start the app first.${NC}"
        exit 1
    fi

    # Generate the Caddyfile via rake task
    echo "  Querying tenant subdomains..."
    docker compose -f "$COMPOSE_FILE" exec -T web bundle exec rake caddyfile:generate CADDYFILE_OUTPUT=/app/$CADDYFILE_GENERATED

    # Copy the generated file out of the container
    docker cp "$WEB_CONTAINER":/app/$CADDYFILE_GENERATED ./$CADDYFILE_GENERATED

    # Check if anything changed
    if [ -f "$CADDYFILE" ]; then
        # Compare ignoring the timestamp comment line
        CURRENT_CONTENT=$(grep -v "^# Generated at:" "$CADDYFILE" 2>/dev/null || true)
        NEW_CONTENT=$(grep -v "^# Generated at:" "$CADDYFILE_GENERATED" 2>/dev/null || true)

        if [ "$CURRENT_CONTENT" = "$NEW_CONTENT" ]; then
            echo ""
            echo -e "${GREEN}✓ No changes needed${NC}"
            echo "Caddyfile is already up to date."
            rm -f "$CADDYFILE_GENERATED"
            exit 0
        fi
    fi

    # Show diff
    echo ""
    echo "Changes detected:"
    if [ -f "$CADDYFILE" ]; then
        diff -u "$CADDYFILE" "$CADDYFILE_GENERATED" || true
    else
        echo "  (new file)"
        cat "$CADDYFILE_GENERATED"
    fi
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Dry run - not applying changes${NC}"
        rm -f "$CADDYFILE_GENERATED"
        exit 0
    fi

    # Apply the new Caddyfile
    echo "  Applying new Caddyfile..."
    mv "$CADDYFILE_GENERATED" "$CADDYFILE"

    # Reload Caddy if running
    CADDY_CONTAINER=$(get_caddy_container)
    if [ -n "$CADDY_CONTAINER" ]; then
        echo "  Reloading Caddy..."
        docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

        echo ""
        echo -e "${GREEN}✓ Caddyfile updated and Caddy reloaded${NC}"
    else
        echo ""
        echo -e "${GREEN}✓ Caddyfile updated${NC}"
        echo -e "${YELLOW}Note: Caddy not running. Changes will apply on next start.${NC}"
    fi
}

show_usage() {
    echo "Usage: $0 [--dry-run]"
    echo ""
    echo "Generates Caddyfile from tenant subdomains in the database."
    echo "This script is idempotent - safe to run anytime."
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would change without applying"
    echo ""
    echo "Example:"
    echo "  $0            # Generate and apply Caddyfile"
    echo "  $0 --dry-run  # Preview changes only"
}

# Main
case "${1:-}" in
    --help|-h)
        show_usage
        exit 0
        ;;
    --dry-run|"")
        detect_environment
        generate_caddyfile
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
