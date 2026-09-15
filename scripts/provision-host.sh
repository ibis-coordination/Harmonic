#!/bin/bash
# provision-host.sh — idempotent host-level provisioning for a Harmonic
# production droplet. Everything here is config the compose file cannot
# express: swap, sysctl. Run as root on a fresh Ubuntu host or re-run on an
# existing one; each step converges to the same state and skips work already
# done. Application-level setup (files under /opt/harmonic, .env, deploys)
# is documented in docs/DEPLOYMENT.md.
#
# Usage: sudo ./provision-host.sh
#   SWAP_SIZE_GB=4 (default) — size of /swapfile.

set -euo pipefail

SWAP_SIZE_GB="${SWAP_SIZE_GB:-4}"
SWAPFILE="/swapfile"
SYSCTL_DROPIN="/etc/sysctl.d/90-harmonic.conf"

log()  { echo "provision-host: $*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "provision-host: must run as root" >&2
  exit 1
fi

# --- Swap -------------------------------------------------------------
# Without swap, a slow memory leak ends in a reclaim livelock: both CPUs
# pin at 100%, SSH cannot fork, and the box needs a power cycle (observed
# 2026-09-15). Swap converts that failure mode into gradual degradation
# and gives monitoring weeks of warning instead of none.
wanted_bytes=$((SWAP_SIZE_GB * 1024 * 1024 * 1024))
current_bytes=0
if [[ -f "$SWAPFILE" ]]; then
  current_bytes=$(stat -c%s "$SWAPFILE")
fi

if [[ "$current_bytes" -eq "$wanted_bytes" ]] && swapon --show=NAME --noheadings | grep -q "^${SWAPFILE}$"; then
  log "swap: ${SWAP_SIZE_GB}G swapfile already active — skipping"
else
  if swapon --show=NAME --noheadings | grep -q "^${SWAPFILE}$"; then
    log "swap: resizing ${SWAPFILE} to ${SWAP_SIZE_GB}G"
    swapoff "$SWAPFILE"
  fi
  log "swap: creating ${SWAP_SIZE_GB}G ${SWAPFILE}"
  fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE"
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  swapon "$SWAPFILE"
fi

if ! grep -qE "^${SWAPFILE}\s" /etc/fstab; then
  log "swap: adding ${SWAPFILE} to /etc/fstab"
  echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
else
  log "swap: fstab entry present — skipping"
fi

# --- Sysctl -----------------------------------------------------------
# swappiness=10: prefer keeping working memory resident; use swap as an
# emergency buffer, not a cache extension.
log "sysctl: writing ${SYSCTL_DROPIN}"
cat > "$SYSCTL_DROPIN" <<'SYSCTL'
# Managed by scripts/provision-host.sh — edit there, not here.
vm.swappiness=10
SYSCTL
sysctl --quiet --load "$SYSCTL_DROPIN"

log "done"
swapon --show
sysctl vm.swappiness
