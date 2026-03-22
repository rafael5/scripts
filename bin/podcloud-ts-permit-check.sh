#!/usr/bin/env bash
# =============================================================================
#  PodCloud — Tailscale Cert Permit Check (Script 2 of 3)
#  Version:  1.0.0
#  Target:   Raspberry Pi 5 · Debian Bookworm · aarch64 · bash 5.x
#
#  Purpose:
#    Verify that TS_PERMIT_CERT_UID=root is correctly set in BOTH:
#      1. /etc/default/tailscaled  (config file — persists across reboots)
#      2. The live tailscaled process environment (active right now)
#
#    This single condition is the only Tailscale prerequisite for Caddy to
#    fetch HTTPS certificates from the local tailscaled socket.
#
#  THIS SCRIPT IS ENTIRELY READ-ONLY.
#  It does not restart, signal, modify, or interact with tailscaled in any way.
#  It is safe to run over a Tailscale SSH session with zero risk of
#  losing connectivity.
#
#  Run order:
#    Step 1:  sudo bash podcloud_tailscale_check.sh    (Tailscale health)
#    Step 2:  sudo bash podcloud_ts_permit_check.sh    (this script)
#    Step 3:  sudo bash podcloud_install.sh            (Docker/Caddy install)
#
#  Exit codes:
#    0 — both checks pass, safe to run podcloud_install.sh
#    1 — one or both checks failed, follow the printed instructions first
#
#  Usage:
#    sudo bash podcloud_ts_permit_check.sh
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# =============================================================================
#  1. CONSTANTS
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly TAILSCALED_DEFAULTS="/etc/default/tailscaled"
readonly REQUIRED_UID="root"

# =============================================================================
#  2. COLOURS
# =============================================================================

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# =============================================================================
#  3. STATE — initialise ALL variables (prevents set -u aborts)
# =============================================================================

PASS=0
FAIL=0
WARN=0

FILE_VALUE=""       # raw value from config file
FILE_HAS_ROOT=0     # 1 if config file contains root
LIVE_VALUE=""       # raw value from running process environment
LIVE_HAS_ROOT=0     # 1 if running process has root
TS_PID=""           # tailscaled PID

declare -a FAILURES=()
declare -a ACTIONS=()

# =============================================================================
#  4. HELPERS
# =============================================================================

# Safe counter increment — never use ((VAR++)); exits 1 when VAR=0
inc() { local _v="${!1}"; eval "$1=$(( _v + 1 ))"; return 0; }

_log() { echo -e "$(date '+%H:%M:%S') $*"; }
pass() { _log "${GREEN}  ✔ PASS${RESET}  $*"; inc PASS; }
fail() { _log "${RED}  ✖ FAIL${RESET}  $*"; inc FAIL; FAILURES+=("$*"); }
warn() { _log "${YELLOW}  ⚠ WARN${RESET}  $*"; inc WARN; }
info() { _log "${CYAN}  ℹ INFO${RESET}  $*"; }

# =============================================================================
#  BANNER
# =============================================================================

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   PodCloud — Tailscale Cert Permit Check  (Script 2 of 3)   ║${RESET}"
echo -e "${BOLD}${CYAN}║   Version ${SCRIPT_VERSION}  ·  READ-ONLY  ·  Safe over Tailscale SSH    ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# =============================================================================
#  CHECK 1 — Must run as root (needed to read /proc/<pid>/environ)
# =============================================================================

echo -e "${BOLD}Check 1: Privileges${RESET}"

if [[ "$EUID" -ne 0 ]]; then
    fail "Must run as root — fix: sudo bash $0"
    echo -e "\n${RED}Re-run with sudo.${RESET}\n"
    exit 1
fi
pass "Running as root"
echo ""

# =============================================================================
#  CHECK 2 — Config file: /etc/default/tailscaled contains TS_PERMIT_CERT_UID=root
# =============================================================================

echo -e "${BOLD}Check 2: Config file — ${TAILSCALED_DEFAULTS}${RESET}"

if [[ ! -f "$TAILSCALED_DEFAULTS" ]]; then
    fail "Config file not found: ${TAILSCALED_DEFAULTS}"
    ACTIONS+=("Create the file and add the required setting:")
    ACTIONS+=("  sudo mkdir -p /etc/default")
    ACTIONS+=("  echo 'TS_PERMIT_CERT_UID=root' | sudo tee -a ${TAILSCALED_DEFAULTS}")
    ACTIONS+=("Then reboot the Pi (safest) or restart tailscaled when NOT on a Tailscale SSH session.")
else
    pass "Config file exists: ${TAILSCALED_DEFAULTS}"

    # Read the raw value — grep exits 1 on no match, capture safely
    FILE_VALUE_RAW=$(grep "^TS_PERMIT_CERT_UID" "$TAILSCALED_DEFAULTS" 2>/dev/null || true)
    FILE_VALUE=$(echo "$FILE_VALUE_RAW" | tr -d '[:space:]')
    FILE_VALUE="${FILE_VALUE:-}"

    if [[ -z "$FILE_VALUE" ]]; then
        fail "TS_PERMIT_CERT_UID is not set in ${TAILSCALED_DEFAULTS}"
        ACTIONS+=("Add the required setting to the config file:")
        ACTIONS+=("  echo 'TS_PERMIT_CERT_UID=root' | sudo tee -a ${TAILSCALED_DEFAULTS}")
        ACTIONS+=("Then reboot the Pi (safest) or restart tailscaled when NOT on a Tailscale SSH session.")
    else
        info "Found in config file: ${FILE_VALUE}"
        # Value may be comma-separated (e.g. caddy,root or root,caddy)
        # Check each token — note: grep -q exits 1 on no match, use direct if
        if echo "$FILE_VALUE" | grep -q "root\|^TS_PERMIT_CERT_UID=0$"; then
            pass "Config file value includes 'root': ${FILE_VALUE}"
            FILE_HAS_ROOT=1
        else
            fail "Config file has TS_PERMIT_CERT_UID but does not include 'root' (found: ${FILE_VALUE})"
            ACTIONS+=("Append root to the existing value in ${TAILSCALED_DEFAULTS}:")
            ACTIONS+=("  sudo sed -i 's/^TS_PERMIT_CERT_UID=.*/&,root/' ${TAILSCALED_DEFAULTS}")
            ACTIONS+=("Then reboot the Pi (safest) or restart tailscaled when NOT on a Tailscale SSH session.")
        fi
    fi
fi
echo ""

# =============================================================================
#  CHECK 3 — Live process environment: running tailscaled has TS_PERMIT_CERT_UID=root
# =============================================================================

echo -e "${BOLD}Check 3: Live process environment — running tailscaled${RESET}"

# Get tailscaled PID — pgrep exits 1 if no match, capture safely
TS_PID_RAW=$(pgrep -x tailscaled 2>/dev/null || true)
TS_PID=$(echo "$TS_PID_RAW" | tr -d '[:space:]' | head -c 20)
TS_PID="${TS_PID:-}"

if [[ -z "$TS_PID" ]]; then
    fail "tailscaled process not found — is Tailscale running?"
    ACTIONS+=("Start tailscaled: sudo systemctl start tailscaled")
else
    pass "tailscaled is running (PID: ${TS_PID})"

    # Read the process environment from /proc — strings converts null-delimited
    # entries to newlines. grep exits 1 on no match, capture safely.
    LIVE_VALUE_RAW=$(strings "/proc/${TS_PID}/environ" 2>/dev/null \
        | grep "^TS_PERMIT_CERT_UID" || true)
    LIVE_VALUE=$(echo "$LIVE_VALUE_RAW" | tr -d '[:space:]')
    LIVE_VALUE="${LIVE_VALUE:-}"

    if [[ -z "$LIVE_VALUE" ]]; then
        # Not in live environment — this means tailscaled started before the
        # config file was written, or has never been restarted since it was added.
        if [[ $FILE_HAS_ROOT -eq 1 ]]; then
            warn "TS_PERMIT_CERT_UID is in the config file but NOT in the live process environment."
            warn "tailscaled must be restarted once to load it."
            info "The config file is correct — this will resolve itself on next Pi reboot."
            info "To apply now without losing SSH: reboot the Pi after the install completes."
            info "  sudo reboot"
            info "Do NOT restart tailscaled mid-session over a Tailscale SSH connection."
            # This is a WARN not a FAIL — the install can proceed; Caddy will
            # retry cert fetching and succeed after the reboot.
        else
            fail "TS_PERMIT_CERT_UID is neither in the config file nor in the live process."
        fi
    else
        info "Found in live process environment: ${LIVE_VALUE}"
        if echo "$LIVE_VALUE" | grep -q "root"; then
            pass "Live tailscaled process has TS_PERMIT_CERT_UID including 'root'"
            LIVE_HAS_ROOT=1
        else
            fail "Live tailscaled process has TS_PERMIT_CERT_UID but does not include 'root' (found: ${LIVE_VALUE})"
            ACTIONS+=("The config file needs 'root' added, then a Pi reboot to apply:")
            ACTIONS+=("  sudo sed -i 's/^TS_PERMIT_CERT_UID=.*/&,root/' ${TAILSCALED_DEFAULTS}")
            ACTIONS+=("  sudo reboot")
        fi
    fi
fi
echo ""

# =============================================================================
#  SUMMARY
# =============================================================================

echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${GREEN}PASS${RESET}: ${PASS}   ${YELLOW}WARN${RESET}: ${WARN}   ${RED}FAIL${RESET}: ${FAIL}"
echo ""

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}Failures:${RESET}"
    for F in "${FAILURES[@]}"; do
        echo -e "    ${RED}✖${RESET} ${F}"
    done
    echo ""
fi

if [[ ${#ACTIONS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Required actions before running podcloud_install.sh:${RESET}"
    for A in "${ACTIONS[@]}"; do
        echo -e "    ${A}"
    done
    echo ""
fi

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}✔ All checks passed.${RESET}"
    echo -e "  ${BOLD}Safe to proceed:${RESET} sudo bash podcloud_install.sh"
    echo ""
    exit 0

elif [[ $FAIL -eq 0 && $WARN -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}✔ No blocking failures — install can proceed.${RESET}"
    echo -e "  ${YELLOW}However, Caddy cert fetch may fail on first start until you reboot.${RESET}"
    echo -e "  ${BOLD}Recommended:${RESET} run the install, then reboot the Pi when done."
    echo -e "  ${BOLD}Proceed:${RESET} sudo bash podcloud_install.sh"
    echo ""
    exit 0

else
    echo -e "  ${RED}${BOLD}✖ ${FAIL} check(s) failed. Follow the actions above before installing.${RESET}"
    echo ""
    exit 1
fi
