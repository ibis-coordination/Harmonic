#!/bin/bash
# Toggle maintenance mode on/off
# Usage: ./scripts/maintenance.sh [on|off|status]
#
# Works in both development and production environments.
# Auto-detects environment based on HOST_MODE in .env

set -e
cd "$(dirname "$0")/.."

CADDYFILE="Caddyfile"
CADDYFILE_MAINTENANCE="Caddyfile.maintenance"
CADDYFILE_BACKUP="Caddyfile.backup"
MAINTENANCE_HTML="config/maintenance/maintenance.html"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Detect environment and set compose file
detect_environment() {
    # Check RAILS_ENV
    RAILS_ENV_FROM_ENV=$(grep -E "^RAILS_ENV=" .env 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || true)

    if [ "$RAILS_ENV" = "production" ] || [ "$RAILS_ENV_FROM_ENV" = "production" ]; then
        COMPOSE_FILE="docker-compose.production.yml"
        ENVIRONMENT="production"
    else
        # Development - check if using caddy profile
        HOST_MODE=$(grep -E "^HOST_MODE=" .env 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || true)
        if [ "$HOST_MODE" = "caddy" ]; then
            COMPOSE_FILE="docker-compose.yml"
            COMPOSE_PROFILES="--profile caddy"
            ENVIRONMENT="development (caddy)"
        else
            echo -e "${RED}Error: Maintenance mode requires Caddy.${NC}"
            echo ""
            echo "Set HOST_MODE=caddy in .env and restart with ./scripts/start.sh"
            echo "Or use docker-compose.production.yml for production."
            exit 1
        fi
    fi
}

show_usage() {
    echo "Usage: $0 [on|off|status]"
    echo ""
    echo "Commands:"
    echo "  on      Enable maintenance mode (shows maintenance page)"
    echo "  off     Disable maintenance mode (restore normal operation)"
    echo "  status  Check current maintenance mode status"
    echo ""
    echo "Example:"
    echo "  $0 on     # Enable maintenance mode before migration"
    echo "  $0 off    # Disable after deployment is complete"
}

is_maintenance_mode() {
    # Check if backup exists (indicates maintenance mode is on)
    if [ -f "$CADDYFILE_BACKUP" ]; then
        return 0  # true - maintenance mode is on
    else
        return 1  # false - maintenance mode is off
    fi
}

get_caddy_container() {
    docker compose -f "$COMPOSE_FILE" ${COMPOSE_PROFILES:-} ps -q caddy 2>/dev/null || true
}

maintenance_on() {
    echo -e "${YELLOW}Enabling maintenance mode...${NC}"
    echo "Environment: $ENVIRONMENT"
    echo ""

    if is_maintenance_mode; then
        echo -e "${YELLOW}Maintenance mode is already enabled.${NC}"
        exit 0
    fi

    # Check required files exist
    if [ ! -f "$CADDYFILE" ]; then
        echo -e "${RED}Error: $CADDYFILE not found.${NC}"
        exit 1
    fi
    if [ ! -f "$CADDYFILE_MAINTENANCE" ]; then
        echo -e "${RED}Error: $CADDYFILE_MAINTENANCE not found.${NC}"
        exit 1
    fi
    if [ ! -f "$MAINTENANCE_HTML" ]; then
        echo -e "${RED}Error: $MAINTENANCE_HTML not found.${NC}"
        exit 1
    fi

    # Backup current Caddyfile
    echo "  Backing up current Caddyfile..."
    cp "$CADDYFILE" "$CADDYFILE_BACKUP"

    # Copy maintenance Caddyfile
    echo "  Switching to maintenance Caddyfile..."
    cp "$CADDYFILE_MAINTENANCE" "$CADDYFILE"

    # Copy maintenance page into caddy container and reload
    CADDY_CONTAINER=$(get_caddy_container)
    if [ -n "$CADDY_CONTAINER" ]; then
        echo "  Copying maintenance page to Caddy container..."
        docker exec "$CADDY_CONTAINER" mkdir -p /srv/public
        docker cp "$MAINTENANCE_HTML" "$CADDY_CONTAINER":/srv/public/maintenance.html

        # Reload Caddy configuration
        echo "  Reloading Caddy..."
        docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

        echo ""
        echo -e "${GREEN}✓ Maintenance mode enabled${NC}"
        echo ""
        echo "The app now shows the maintenance page."
        echo "Run '$0 off' to disable maintenance mode."
    else
        echo -e "${RED}Error: Caddy container not running.${NC}"
        echo "Reverting Caddyfile..."
        mv "$CADDYFILE_BACKUP" "$CADDYFILE"
        exit 1
    fi
}

maintenance_off() {
    echo -e "${YELLOW}Disabling maintenance mode...${NC}"
    echo "Environment: $ENVIRONMENT"
    echo ""

    if ! is_maintenance_mode; then
        echo -e "${YELLOW}Maintenance mode is already disabled.${NC}"
        exit 0
    fi

    # Check backup exists
    if [ ! -f "$CADDYFILE_BACKUP" ]; then
        echo -e "${RED}Error: No backup Caddyfile found. Cannot restore.${NC}"
        exit 1
    fi

    # Restore original Caddyfile
    echo "  Restoring original Caddyfile..."
    mv "$CADDYFILE_BACKUP" "$CADDYFILE"

    # Reload Caddy configuration
    CADDY_CONTAINER=$(get_caddy_container)
    if [ -n "$CADDY_CONTAINER" ]; then
        echo "  Reloading Caddy..."
        docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

        echo ""
        echo -e "${GREEN}✓ Maintenance mode disabled${NC}"
        echo ""
        echo "The app is now serving normally."
    else
        echo -e "${YELLOW}Warning: Caddy container not running. Caddyfile restored but not reloaded.${NC}"
        echo "Start the app to apply changes."
    fi
}

maintenance_status() {
    echo "Maintenance Mode Status"
    echo "======================="
    echo "Environment: $ENVIRONMENT"
    echo ""

    if is_maintenance_mode; then
        echo -e "Status: ${YELLOW}ENABLED${NC}"
        echo "Backup: $CADDYFILE_BACKUP"
    else
        echo -e "Status: ${GREEN}DISABLED${NC}"
        echo "App is serving normally."
    fi

    echo ""

    # Check if Caddy is running
    CADDY_CONTAINER=$(get_caddy_container)
    if [ -n "$CADDY_CONTAINER" ]; then
        CADDY_STATUS=$(docker inspect -f '{{.State.Status}}' "$CADDY_CONTAINER" 2>/dev/null || echo "unknown")
        echo "Caddy: $CADDY_STATUS"
    else
        echo "Caddy: not running"
    fi
}

# Main
detect_environment

case "${1:-}" in
    on)
        maintenance_on
        ;;
    off)
        maintenance_off
        ;;
    status)
        maintenance_status
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
