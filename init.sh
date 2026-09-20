#!/usr/bin/env bash
#
# init.sh — install nfs-stale-monitor on this Proxmox node.
#
# Run it from the root of the cloned repository:
#
#     ./init.sh
#
# It is idempotent: re-running it re-installs the daemon and unit, restarts the
# service, and only creates the config file if one is not already present
# (so your tuned settings are never clobbered).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SRC="$REPO_ROOT/nfs-stale-monitor"
UNIT_SRC="$REPO_ROOT/nfs-stale-monitor.service"
CONF_SRC="$REPO_ROOT/nfs-stale-monitor.conf.example"

BIN=/usr/local/bin/nfs-stale-monitor
UNIT=/etc/systemd/system/nfs-stale-monitor.service
CONF_DIR=/etc/nfs-stale-monitor
CONF="$CONF_DIR/nfs-stale-monitor.conf"

say() { printf '==> %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: this script must be run as root (try: sudo ./init.sh)" >&2
  exit 1
fi

[[ -f "$DAEMON_SRC" ]] || { echo "ERROR: $DAEMON_SRC not found" >&2; exit 1; }
[[ -f "$UNIT_SRC"   ]] || { echo "ERROR: $UNIT_SRC not found"   >&2; exit 1; }

# 1. Install the daemon binary.
say "installing daemon -> $BIN"
install -m 0755 "$DAEMON_SRC" "$BIN"

# 2. Install the config (only if none exists yet).
mkdir -p "$CONF_DIR"
if [[ -f "$CONF" ]]; then
  say "config already present, leaving it untouched: $CONF"
else
  say "creating config -> $CONF"
  install -m 0644 "$CONF_SRC" "$CONF"
fi

# 3. Install the systemd unit and reload.
say "installing systemd unit -> $UNIT"
install -m 0644 "$UNIT_SRC" "$UNIT"
systemctl daemon-reload

# 4. Enable + start (or restart) the service.
say "enabling and (re)starting service"
systemctl enable --now nfs-stale-monitor.service
systemctl restart nfs-stale-monitor.service

# 5. Show status.
echo
systemctl status nfs-stale-monitor.service --no-pager || true

echo
say "done. Check logs with: journalctl -u nfs-stale-monitor -f"
say "Edit $CONF to change the schedule (INTERVAL), then:"
say "    systemctl restart nfs-stale-monitor"
