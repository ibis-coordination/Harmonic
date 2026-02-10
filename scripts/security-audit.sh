#!/bin/bash
#
# Production Server Security Audit Script
# Run on your production server to check common security issues
#
# Usage: ./security-audit.sh [--hostname your-domain.com]
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Counters
PASS=0
WARN=0
FAIL=0

# Defaults - auto-detect hostname and output to log/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_FILE="${PROJECT_DIR}/log/security-audit-$(date +%Y%m%d-%H%M%S).txt"

# Use a different var name to avoid conflict with system HOSTNAME env var
AUDIT_HOSTNAME=""

# Try to auto-detect hostname from .env first (preferred)
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  AUDIT_HOSTNAME=$(grep -E "^HOSTNAME=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
fi

# Fall back to system hostname if .env didn't have it
if [[ -z "$AUDIT_HOSTNAME" ]]; then
  AUDIT_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
fi

# Parse arguments (can override defaults)
while [[ $# -gt 0 ]]; do
  case $1 in
    --hostname)
      AUDIT_HOSTNAME="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --no-output)
      OUTPUT_FILE=""
      shift
      ;;
    *)
      echo "Usage: $0 [--hostname your-domain.com] [--output /path/to/report.txt] [--no-output]"
      exit 1
      ;;
  esac
done

# Set up logging (strip colors for file)
if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  # Redirect stdout through tee, stripping ANSI codes for the file
  exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' > "$OUTPUT_FILE"))
  echo "Report will be saved to: $OUTPUT_FILE"
fi

# Output functions
header() {
  echo ""
  echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  $1${NC}"
  echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
}

pass() {
  echo -e "  ${GREEN}✓ PASS${NC}: $1"
  PASS=$((PASS + 1))
}

warn() {
  echo -e "  ${YELLOW}⚠ WARN${NC}: $1"
  WARN=$((WARN + 1))
}

fail() {
  echo -e "  ${RED}✗ FAIL${NC}: $1"
  FAIL=$((FAIL + 1))
}

info() {
  echo -e "  ${BLUE}ℹ INFO${NC}: $1"
}

# Check if running as root
check_root() {
  if [[ $EUID -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# ============================================================================
# SSH CONFIGURATION
# ============================================================================
check_ssh() {
  header "SSH Configuration"

  local ssh_config="/etc/ssh/sshd_config"

  if [[ ! -f "$ssh_config" ]]; then
    warn "SSH config not found at $ssh_config"
    return
  fi

  # Check PasswordAuthentication
  local pass_auth
  pass_auth=$(grep -E "^PasswordAuthentication" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "not set")
  if [[ "$pass_auth" == "no" ]]; then
    pass "PasswordAuthentication is disabled"
  elif [[ "$pass_auth" == "not set" ]]; then
    warn "PasswordAuthentication not explicitly set (check sshd defaults)"
  else
    fail "PasswordAuthentication is enabled - use SSH keys instead"
  fi

  # Check PermitRootLogin
  local root_login
  root_login=$(grep -E "^PermitRootLogin" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "not set")
  if [[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]]; then
    pass "PermitRootLogin is '$root_login'"
  elif [[ "$root_login" == "not set" ]]; then
    warn "PermitRootLogin not explicitly set (check sshd defaults)"
  else
    fail "PermitRootLogin is '$root_login' - should be 'no' or 'prohibit-password'"
  fi

  # Check SSH port
  local ssh_port
  ssh_port=$(grep -E "^Port" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "22")
  if [[ "$ssh_port" == "22" ]]; then
    info "SSH running on default port 22 (consider changing for obscurity)"
  else
    pass "SSH running on non-default port $ssh_port"
  fi

  # Check for SSH keys
  local auth_keys="$HOME/.ssh/authorized_keys"
  if [[ -f "$auth_keys" ]]; then
    local key_count
    key_count=$(grep -c "^ssh-" "$auth_keys" 2>/dev/null || echo "0")
    if [[ "$key_count" -gt 0 ]]; then
      pass "Found $key_count SSH key(s) in authorized_keys"
    else
      warn "No SSH keys found in authorized_keys"
    fi
  else
    warn "No authorized_keys file found"
  fi
}

# ============================================================================
# FIREWALL
# ============================================================================
check_firewall() {
  header "Firewall (UFW)"

  if ! command -v ufw &> /dev/null; then
    warn "UFW not installed - consider installing: apt install ufw"
    return
  fi

  local ufw_status
  ufw_status=$(ufw status 2>/dev/null | head -1)

  if [[ "$ufw_status" == *"active"* ]]; then
    pass "UFW firewall is active"

    # Check rules
    echo ""
    info "Current UFW rules:"
    ufw status numbered 2>/dev/null | while read -r line; do
      echo "       $line"
    done
  else
    fail "UFW firewall is not active"
    info "Enable with: ufw default deny incoming && ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw enable"
  fi
}

# ============================================================================
# OPEN PORTS
# ============================================================================
check_ports() {
  header "Open Ports"

  info "Ports listening on all interfaces (0.0.0.0 / ::):"
  echo ""

  local dangerous_ports=()

  while IFS= read -r line; do
    local port
    port=$(echo "$line" | awk '{print $5}' | rev | cut -d: -f1 | rev)
    local process
    process=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")

    echo "       Port $port ($process)"

    # Check for commonly dangerous exposed ports
    case $port in
      3306) dangerous_ports+=("3306 (MySQL)") ;;
      5432) dangerous_ports+=("5432 (PostgreSQL)") ;;
      6379) dangerous_ports+=("6379 (Redis)") ;;
      27017) dangerous_ports+=("27017 (MongoDB)") ;;
      11211) dangerous_ports+=("11211 (Memcached)") ;;
    esac
  done < <(ss -tulpn 2>/dev/null | grep -E "0\.0\.0\.0:|:::" | grep -v "127.0.0" || true)

  echo ""

  if [[ ${#dangerous_ports[@]} -gt 0 ]]; then
    for port in "${dangerous_ports[@]}"; do
      fail "Database/cache port exposed publicly: $port"
    done
  else
    pass "No common database/cache ports exposed publicly"
  fi

  # Check for app port bypass
  if ss -tulpn 2>/dev/null | grep -qE "0\.0\.0\.0:3000|:::3000"; then
    warn "Port 3000 exposed publicly - traffic should go through reverse proxy"
  fi
}

# ============================================================================
# SYSTEM UPDATES
# ============================================================================
check_updates() {
  header "System Updates"

  if command -v apt &> /dev/null; then
    apt update -qq 2>/dev/null

    local upgradable
    # apt list outputs a header line, so subtract 1; grep -c returns 0 if no matches
    upgradable=$(apt list --upgradable 2>/dev/null | grep -c "/" || echo "0")
    upgradable="${upgradable//[^0-9]/}"  # strip any non-numeric characters

    if [[ -z "$upgradable" || "$upgradable" -eq 0 ]]; then
      pass "System is up to date"
    else
      warn "$upgradable package(s) can be upgraded"
      info "Run: apt upgrade"
    fi

    # Check unattended-upgrades
    if dpkg -l | grep -q unattended-upgrades; then
      pass "unattended-upgrades is installed"
    else
      warn "unattended-upgrades not installed"
      info "Install with: apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades"
    fi
  else
    info "apt not available - skipping package update check"
  fi
}

# ============================================================================
# DOCKER SECURITY
# ============================================================================
check_docker() {
  header "Docker Security"

  if ! command -v docker &> /dev/null; then
    info "Docker not installed - skipping"
    return
  fi

  # Check Docker socket permissions
  local docker_sock="/var/run/docker.sock"
  if [[ -S "$docker_sock" ]]; then
    local sock_perms
    sock_perms=$(stat -c "%a" "$docker_sock" 2>/dev/null || echo "unknown")
    if [[ "$sock_perms" == "660" || "$sock_perms" == "600" ]]; then
      pass "Docker socket has restricted permissions ($sock_perms)"
    else
      warn "Docker socket permissions are $sock_perms (consider 660)"
    fi
  fi

  # Check for privileged containers
  local privileged_containers
  privileged_containers=$(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}}: {{.HostConfig.Privileged}}' 2>/dev/null | grep "true" || true)

  if [[ -z "$privileged_containers" ]]; then
    pass "No containers running in privileged mode"
  else
    warn "Privileged containers found:"
    echo "$privileged_containers" | while read -r line; do
      echo "       $line"
    done
  fi

  # Check for containers with host network
  local host_network
  host_network=$(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}}: {{.HostConfig.NetworkMode}}' 2>/dev/null | grep "host" || true)

  if [[ -z "$host_network" ]]; then
    pass "No containers using host network mode"
  else
    warn "Containers using host network:"
    echo "$host_network" | while read -r line; do
      echo "       $line"
    done
  fi

  # Check for running containers
  local container_count
  container_count=$(docker ps -q 2>/dev/null | wc -l)
  info "$container_count container(s) currently running"
}

# ============================================================================
# FILE PERMISSIONS
# ============================================================================
check_permissions() {
  header "Sensitive File Permissions"

  # Common locations for .env files
  local env_files=(
    ".env"
    "$HOME/.env"
    "$HOME/app/.env"
    "$HOME/app/Harmonic/.env"
    "/app/.env"
  )

  for env_file in "${env_files[@]}"; do
    if [[ -f "$env_file" ]]; then
      local perms
      perms=$(stat -c "%a" "$env_file" 2>/dev/null || echo "unknown")
      if [[ "$perms" == "600" || "$perms" == "400" ]]; then
        pass ".env file $env_file has secure permissions ($perms)"
      else
        fail ".env file $env_file has permissions $perms (should be 600)"
        info "Fix with: chmod 600 $env_file"
      fi
    fi
  done

  # Check SSH directory
  if [[ -d "$HOME/.ssh" ]]; then
    local ssh_perms
    ssh_perms=$(stat -c "%a" "$HOME/.ssh" 2>/dev/null || echo "unknown")
    if [[ "$ssh_perms" == "700" ]]; then
      pass ".ssh directory has correct permissions (700)"
    else
      fail ".ssh directory has permissions $ssh_perms (should be 700)"
    fi
  fi
}

# ============================================================================
# FAIL2BAN
# ============================================================================
check_fail2ban() {
  header "Fail2ban (Brute Force Protection)"

  if ! command -v fail2ban-client &> /dev/null; then
    warn "Fail2ban not installed"
    info "Install with: apt install fail2ban && systemctl enable fail2ban"
    return
  fi

  if systemctl is-active --quiet fail2ban; then
    pass "Fail2ban is running"

    # Check jail status
    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | tr -d ' \t' || echo "")
    if [[ -n "$jails" ]]; then
      info "Active jails: $jails"
    fi
  else
    fail "Fail2ban is installed but not running"
    info "Start with: systemctl start fail2ban"
  fi
}

# ============================================================================
# SUSPICIOUS PROCESSES
# ============================================================================
check_processes() {
  header "Process Review"

  # Check for crypto miners (common patterns)
  local suspicious
  suspicious=$(ps aux 2>/dev/null | grep -iE "(xmrig|minerd|cgminer|cryptonight|stratum)" | grep -v grep || true)

  if [[ -z "$suspicious" ]]; then
    pass "No obvious crypto mining processes detected"
  else
    fail "Suspicious processes found:"
    echo "$suspicious" | while read -r line; do
      echo "       $line"
    done
  fi

  # Check for processes listening on unusual ports
  info "Top CPU-consuming processes:"
  ps aux --sort=-%cpu 2>/dev/null | head -6 | tail -5 | while read -r line; do
    echo "       $line" | cut -c1-100
  done
}

# ============================================================================
# CRON JOBS
# ============================================================================
check_cron() {
  header "Scheduled Tasks (Cron)"

  info "Root crontab:"
  if crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" > /dev/null; then
    crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | while read -r line; do
      echo "       $line"
    done
  else
    echo "       (empty)"
  fi

  echo ""
  info "System cron directories:"
  for dir in /etc/cron.d /etc/cron.daily /etc/cron.hourly; do
    if [[ -d "$dir" ]]; then
      local count
      count=$(ls -1 "$dir" 2>/dev/null | wc -l)
      echo "       $dir: $count file(s)"
    fi
  done

  pass "Review cron jobs above for anything unexpected"
}

# ============================================================================
# SSL/TLS
# ============================================================================
check_ssl() {
  header "SSL/TLS Configuration"

  if [[ -z "$AUDIT_HOSTNAME" ]]; then
    info "No hostname provided - skipping SSL check"
    info "Run with: $0 --hostname your-domain.com"
    return
  fi

  if ! command -v curl &> /dev/null; then
    warn "curl not available - skipping SSL check"
    return
  fi

  # Check if HTTPS works
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$AUDIT_HOSTNAME" 2>/dev/null || echo "000")

  if [[ "$http_code" == "200" || "$http_code" == "301" || "$http_code" == "302" ]]; then
    pass "HTTPS is working (HTTP $http_code)"
  else
    fail "HTTPS returned HTTP $http_code"
  fi

  # Check certificate expiry
  local expiry
  expiry=$(echo | openssl s_client -servername "$AUDIT_HOSTNAME" -connect "$AUDIT_HOSTNAME:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")

  if [[ -n "$expiry" ]]; then
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_left -gt 30 ]]; then
      pass "SSL certificate valid for $days_left more days (expires: $expiry)"
    elif [[ $days_left -gt 0 ]]; then
      warn "SSL certificate expires in $days_left days (expires: $expiry)"
    else
      fail "SSL certificate has expired!"
    fi
  fi

  info "For detailed SSL analysis: https://www.ssllabs.com/ssltest/analyze.html?d=$AUDIT_HOSTNAME"
}

# ============================================================================
# SUMMARY
# ============================================================================
print_summary() {
  header "Security Audit Summary"

  echo ""
  echo -e "  ${GREEN}Passed:  $PASS${NC}"
  echo -e "  ${YELLOW}Warnings: $WARN${NC}"
  echo -e "  ${RED}Failed:  $FAIL${NC}"
  echo ""

  if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}⚠ Action required: Please address the failed checks above.${NC}"
  elif [[ $WARN -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Review the warnings above for potential improvements.${NC}"
  else
    echo -e "  ${GREEN}${BOLD}✓ All checks passed!${NC}"
  fi
  echo ""
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  echo ""
  echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║          Production Server Security Audit                     ║${NC}"
  echo -e "${BOLD}║          $(date '+%Y-%m-%d %H:%M:%S')                                  ║${NC}"
  echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"

  if ! check_root; then
    echo ""
    warn "Not running as root - some checks may be incomplete"
    info "Run with: sudo $0 $*"
  fi

  check_ssh
  check_firewall
  check_ports
  check_updates
  check_docker
  check_permissions
  check_fail2ban
  check_processes
  check_cron
  check_ssl

  print_summary
}

main "$@"
