#!/usr/bin/env bash
# =============================================================================
#  install.sh — minty-network-watchdog installer
#  Run as root: sudo bash install.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}✔${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
die()  { echo -e "${RED}✘${RESET} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root: sudo bash install.sh"

echo "Installing minty-network-watchdog..."
echo ""

# 1. Deploy watchdog script
install -m 750 "${SCRIPT_DIR}/minty-network-watchdog.sh" /usr/local/sbin/minty-network-watchdog.sh
ok "Installed script → /usr/local/sbin/minty-network-watchdog.sh"

# 2. Deploy systemd units
install -m 644 "${SCRIPT_DIR}/minty-network-watchdog.service" /etc/systemd/system/minty-network-watchdog.service
install -m 644 "${SCRIPT_DIR}/minty-network-watchdog.timer"   /etc/systemd/system/minty-network-watchdog.timer
ok "Installed systemd units"

# 3. Create optional env file (for TS_AUTHKEY) if it doesn't exist
if [[ ! -f /etc/minty-network-watchdog.env ]]; then
  cat > /etc/minty-network-watchdog.env <<'EOF'
# Optional: set Tailscale auth key for headless re-authentication
# TS_AUTHKEY=tskey-auth-...
EOF
  chmod 640 /etc/minty-network-watchdog.env
  ok "Created /etc/minty-network-watchdog.env (edit to add TS_AUTHKEY)"
else
  warn "/etc/minty-network-watchdog.env already exists — not overwritten"
fi

# 4. Create state directory
mkdir -p /var/lib/minty-network-watchdog
ok "Created state dir /var/lib/minty-network-watchdog"

# 5. Enable and start the timer
systemctl daemon-reload
systemctl enable --now minty-network-watchdog.timer
ok "Timer enabled and started"

echo ""
echo "Done. Timer will first run 2 minutes after boot, then every 5 minutes."
echo ""
echo "Useful commands:"
echo "  systemctl list-timers minty-network-watchdog.timer   # next run time"
echo "  systemctl start minty-network-watchdog.service       # run check now"
echo "  journalctl -fu minty-network-watchdog.service        # live log"
echo "  tail -f /var/log/minty-network-watchdog.log          # persistent log"
