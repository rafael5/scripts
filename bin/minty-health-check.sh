#!/usr/bin/env bash
# =============================================================================
#  minty-health-check.sh
#  Version: 1.0.0
#  Description: Health check for SSH, Tailscale, and RustDesk config,
#               status, and resilience on minty (Linux Mint / Ubuntu 24.04)
#  Run as: normal user (sudo access required for some checks)
# =============================================================================
 
set -uo pipefail
 
# =============================================================================
#  CONSTANTS
# =============================================================================
 
TAILSCALE_HOSTNAME="minty.warg-torino.ts.net"
SSH_PORT=22
SSH_ALIVE_INTERVAL_MIN=30
SSH_ALIVE_COUNT_MIN=3
TAILSCALE_OVERRIDE="/etc/systemd/system/tailscaled.service.d/override.conf"
 
PASS=0
WARN=0
FAIL=0
 
# =============================================================================
#  HELPERS
# =============================================================================
 
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
 
pass()  { echo -e "  ${GREEN}✔${RESET}  $*"; (( PASS++ ))  || true; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $*"; (( WARN++ )) || true; }
fail()  { echo -e "  ${RED}✘${RESET}  $*"; (( FAIL++ ))   || true; }
info()  { echo -e "  ${CYAN}·${RESET}  $*"; }
section() { echo -e "\n${BOLD}━━━ $* ${RESET}"; }
 
has_cmd() { command -v "$1" >/dev/null 2>&1; }
 
svc_enabled() {
  local raw
  raw=$(systemctl is-enabled "$1" 2>/dev/null || true)
  [[ "$raw" == "enabled" ]]
}
 
svc_active() {
  local raw
  raw=$(systemctl is-active "$1" 2>/dev/null || true)
  [[ "$raw" == "active" ]]
}
 
# =============================================================================
#  1. SSH
# =============================================================================
 
check_ssh() {
  section "SSH"
 
  # Service status
  if svc_active ssh || svc_active sshd; then
    pass "sshd service is active"
  else
    fail "sshd is not running — run: sudo systemctl start ssh"
  fi
 
  if svc_enabled ssh || svc_enabled sshd; then
    pass "sshd is enabled (survives reboot)"
  else
    fail "sshd is not enabled — run: sudo systemctl enable ssh"
  fi
 
  # Port accepting connections
  if timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${SSH_PORT}" 2>/dev/null; then
    pass "Port ${SSH_PORT} is accepting connections"
  else
    fail "Port ${SSH_PORT} is not reachable locally"
  fi
 
  # Keepalive config
  local interval count
  interval=$(grep -E '^\s*ClientAliveInterval' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || true)
  count=$(grep -E '^\s*ClientAliveCountMax' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || true)
 
  if [[ -n "$interval" && "$interval" -ge "$SSH_ALIVE_INTERVAL_MIN" ]]; then
    pass "ClientAliveInterval = ${interval}s (≥ ${SSH_ALIVE_INTERVAL_MIN})"
  else
    warn "ClientAliveInterval not set or too low — add to /etc/ssh/sshd_config: ClientAliveInterval 60"
  fi
 
  if [[ -n "$count" && "$count" -ge "$SSH_ALIVE_COUNT_MIN" ]]; then
    pass "ClientAliveCountMax = ${count} (≥ ${SSH_ALIVE_COUNT_MIN})"
  else
    warn "ClientAliveCountMax not set or too low — add to /etc/ssh/sshd_config: ClientAliveCountMax 10"
  fi

  # sshd config syntax test
  if sudo sshd -t 2>/dev/null; then
    pass "sshd_config syntax is valid"
  else
    fail "sshd_config has errors — run: sudo sshd -t"
  fi

  # authorized_keys permissions
  local ak_file="$HOME/.ssh/authorized_keys"
  if [[ -f "$ak_file" ]]; then
    local ak_perms
    ak_perms=$(stat -c '%a' "$ak_file")
    if [[ "$ak_perms" == "600" || "$ak_perms" == "400" ]]; then
      pass "authorized_keys permissions: ${ak_perms}"
    else
      fail "authorized_keys permissions are ${ak_perms} — run: chmod 600 ~/.ssh/authorized_keys"
    fi
  else
    warn "~/.ssh/authorized_keys not found — key auth may not be configured"
  fi
}
 
# =============================================================================
#  2. FIREWALL (UFW)
# =============================================================================

check_firewall() {
  section "Firewall (UFW)"

  if ! has_cmd ufw; then
    warn "ufw not installed — port 22 exposure unknown"
    return
  fi

  local ufw_status
  ufw_status=$(sudo ufw status 2>/dev/null || true)

  if echo "$ufw_status" | grep -q "^Status: active"; then
    pass "UFW is active"
  else
    fail "UFW is inactive — run: sudo ufw enable"
    return
  fi

  # Port 22 should NOT be open publicly — Tailscale is the access path
  if echo "$ufw_status" | grep -qE "^22/tcp|^22 |^OpenSSH"; then
    warn "Port 22 is open in UFW — consider closing it since access is via Tailscale"
  else
    pass "Port 22 not exposed publicly (correct — SSH access via Tailscale)"
  fi
}

# =============================================================================
#  3. TAILSCALE
# =============================================================================
 
check_tailscale() {
  section "Tailscale"
 
  # Binary present
  if has_cmd tailscale; then
    pass "tailscale binary found: $(command -v tailscale)"
  else
    fail "tailscale not installed — see https://tailscale.com/download/linux"
    return
  fi
 
  # Daemon service
  if svc_active tailscaled; then
    pass "tailscaled service is active"
  else
    fail "tailscaled is not running — run: sudo systemctl start tailscaled"
  fi
 
  if svc_enabled tailscaled; then
    pass "tailscaled is enabled (survives reboot)"
  else
    fail "tailscaled is not enabled — run: sudo systemctl enable tailscaled"
  fi
 
  # Tailscale up / peer status
  local ts_status
  ts_status=$(tailscale status 2>/dev/null || true)
 
  local ts_shortname
  ts_shortname=$(echo "$TAILSCALE_HOSTNAME" | cut -d. -f1)
  if echo "$ts_status" | grep -qE "^${TAILSCALE_HOSTNAME}|[[:space:]]${ts_shortname}[[:space:]]"; then
    pass "Node is up as ${TAILSCALE_HOSTNAME}"
  elif echo "$ts_status" | grep -qi "logged out\|not logged in"; then
    fail "Tailscale is logged out — run: sudo tailscale up"
  elif echo "$ts_status" | head -1 | grep -qi "offline"; then
    warn "Tailscale self reports offline — run: sudo tailscale up"
  else
    info "Tailscale status (first 3 lines):"
    echo "$ts_status" | head -3 | sed 's/^/       /'
  fi
 
  # Tailscale IP
  local ts_ip
  ts_ip=$(tailscale ip -4 2>/dev/null || true)
  if [[ -n "$ts_ip" ]]; then
    pass "Tailscale IPv4: ${ts_ip}"
  else
    warn "Could not retrieve Tailscale IP — is tailscale up?"
  fi
 
  # systemd override for network-online.target
  if [[ -f "$TAILSCALE_OVERRIDE" ]]; then
    if grep -q "network-online.target" "$TAILSCALE_OVERRIDE"; then
      pass "systemd override present with network-online.target dependency"
    else
      warn "Override file exists but missing network-online.target — check ${TAILSCALE_OVERRIDE}"
    fi
  else
    warn "No systemd override found — Tailscale may start before network is ready"
    warn "Fix: sudo systemctl edit tailscaled  # add After=network-online.target"
  fi
 
  # NetworkManager-wait-online
  if svc_enabled NetworkManager-wait-online; then
    pass "NetworkManager-wait-online.service is enabled"
  else
    warn "NetworkManager-wait-online not enabled — run: sudo systemctl enable NetworkManager-wait-online.service"
  fi
}
 
# =============================================================================
#  4. RUSTDESK
# =============================================================================
 
check_rustdesk() {
  section "RustDesk"
 
  if has_cmd rustdesk; then
    pass "rustdesk binary found: $(command -v rustdesk)"
  else
    warn "rustdesk binary not found in PATH — may be installed elsewhere"
  fi
 
  if svc_active rustdesk; then
    pass "rustdesk service is active"
  else
    fail "rustdesk service is not running — run: sudo systemctl start rustdesk"
  fi
 
  if svc_enabled rustdesk; then
    pass "rustdesk is enabled (survives reboot)"
  else
    fail "rustdesk is not enabled — run: sudo systemctl enable rustdesk"
  fi
 
  # Confirm it's a system service (not user-session only)
  local unit_path
  unit_path=$(systemctl show rustdesk --property=FragmentPath 2>/dev/null | cut -d= -f2 || true)
  if [[ "$unit_path" == /etc/systemd/system/* || "$unit_path" == /lib/systemd/system/* || "$unit_path" == /usr/lib/systemd/system/* ]]; then
    pass "Running as system service: ${unit_path}"
  elif [[ -n "$unit_path" ]]; then
    warn "Unit path unexpected: ${unit_path} — verify it's not a user-session unit"
  fi

  # Virtual display (headless black-screen prevention)
  local has_display=false
  if [[ -n "${DISPLAY:-}" ]]; then
    pass "Active DISPLAY found: ${DISPLAY}"
    has_display=true
  fi
  if has_cmd Xvfb || has_cmd xvfb-run; then
    pass "Xvfb available for virtual display"
    has_display=true
  fi
  if [[ "$has_display" == false ]]; then
    warn "No virtual display or Xvfb found — RustDesk may show black screen on headless system"
    warn "Install: sudo apt install xvfb"
  fi
}
 
# =============================================================================
#  5. SLEEP / SUSPEND RESILIENCE
# =============================================================================
 
check_sleep() {
  section "Sleep / Suspend Resilience"
 
  for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    local state
    state=$(systemctl is-enabled "$target" 2>/dev/null || true)
    if [[ "$state" == "masked" ]]; then
      pass "${target} is masked"
    else
      fail "${target} is NOT masked (state: ${state}) — run: sudo systemctl mask ${target}"
    fi
  done
}
 
# =============================================================================
#  6. SYSTEM HEALTH
# =============================================================================

check_system() {
  section "System Health"

  # Disk space (deduplicated by mount point)
  while IFS= read -r line; do
    local use mount
    use=$(echo "$line" | awk '{print $1}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $2}')
    if [[ "$use" -ge 95 ]]; then
      fail "Disk ${mount}: ${use}% used — critically full"
    elif [[ "$use" -ge 85 ]]; then
      warn "Disk ${mount}: ${use}% used — getting full"
    else
      pass "Disk ${mount}: ${use}% used"
    fi
  done < <(df --output=pcent,target / /home 2>/dev/null | tail -n +2 | sort -u -k2)

  # Failed systemd units (exclude known-harmless Live ISO leftover)
  local failed_units
  failed_units=$(systemctl list-units --state=failed --no-legend 2>/dev/null \
    | grep -v "casper-md5check" || true)
  local failed_count
  failed_count=$(echo "$failed_units" | grep -c "failed" || true)
  if [[ "$failed_count" -eq 0 ]]; then
    pass "No failed systemd units"
  else
    fail "${failed_count} failed systemd unit(s):"
    echo "$failed_units" | sed 's/^/       /'
  fi

  # Internet reachability
  if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    pass "Internet reachable (8.8.8.8)"
  else
    fail "Cannot reach 8.8.8.8 — check network/routing"
  fi

  # Last boot time (warn if < 10 min — possible unexpected reboot)
  local uptime_secs boot_time
  uptime_secs=$(awk '{print int($1)}' /proc/uptime)
  boot_time=$(uptime -s)
  if [[ "$uptime_secs" -lt 600 ]]; then
    warn "System booted recently ($(( uptime_secs / 60 ))m ago at ${boot_time}) — possible unexpected reboot"
  else
    pass "Uptime: $(uptime -p) (booted ${boot_time})"
  fi
}

# =============================================================================
#  7. AUTO-LOGIN (DESKTOP SESSION)
# =============================================================================

check_autologin() {
  section "Auto-login (Desktop Session)"

  local config="/etc/lightdm/lightdm.conf"
  if [[ ! -f "$config" ]]; then
    warn "LightDM config not found at ${config} — auto-login status unknown"
    return
  fi

  local autologin_user
  autologin_user=$(grep -E '^\s*autologin-user\s*=' "$config" 2>/dev/null \
    | head -1 | cut -d= -f2 | tr -d ' ')

  if [[ -n "$autologin_user" ]]; then
    pass "Auto-login enabled for user: ${autologin_user}"
  else
    fail "Auto-login not configured — RustDesk will show black screen after reboot"
    fail "Fix: set autologin-user=$(whoami) in ${config} under [Seat:*]"
  fi
}

# =============================================================================
#  8. SERVICE RESTART POLICIES
# =============================================================================

check_restart_policies() {
  section "Service Restart Policies"

  for svc in tailscaled rustdesk ssh; do
    local restart
    restart=$(systemctl show "$svc" --property=Restart 2>/dev/null | cut -d= -f2 || true)
    case "$restart" in
      on-failure|always|on-abnormal)
        pass "${svc}: Restart=${restart}" ;;
      no|"")
        warn "${svc}: Restart=no — will not auto-recover from crashes" ;;
      *)
        info "${svc}: Restart=${restart}" ;;
    esac
  done
}

# =============================================================================
#  9. NTP / TIME SYNC
# =============================================================================

check_ntp() {
  section "Time Sync (NTP)"

  local ts_output
  ts_output=$(timedatectl status 2>/dev/null || true)

  if echo "$ts_output" | grep -q "NTP service: active"; then
    pass "NTP service is active"
  else
    fail "NTP is not active — clock drift may break Tailscale and TLS"
    fail "Fix: sudo timedatectl set-ntp true"
  fi

  if echo "$ts_output" | grep -q "System clock synchronized: yes"; then
    pass "System clock is synchronized"
  else
    warn "System clock may not be synchronized yet"
  fi
}

# =============================================================================
#  10. SWAP
# =============================================================================

check_swap() {
  section "Swap"

  local swap_total
  swap_total=$(free -b | awk '/^Swap:/{print $2}')

  if [[ "$swap_total" -gt 0 ]]; then
    local swap_human
    swap_human=$(free -h | awk '/^Swap:/{print $2}')
    pass "Swap present: ${swap_human}"
  else
    warn "No swap configured — OOM may kill Tailscale or RustDesk under memory pressure"
    warn "Fix: sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
  fi
}

# =============================================================================
#  11. SUMMARY
# =============================================================================
 
print_summary() {
  local total=$(( PASS + WARN + FAIL ))
  echo -e "\n${BOLD}━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${GREEN}✔ Pass${RESET}  ${PASS}   ${YELLOW}⚠ Warn${RESET}  ${WARN}   ${RED}✘ Fail${RESET}  ${FAIL}   Total  ${total}"
 
  if [[ $FAIL -gt 0 ]]; then
    echo -e "\n  ${RED}${BOLD}Action required — see ✘ items above.${RESET}"
  elif [[ $WARN -gt 0 ]]; then
    echo -e "\n  ${YELLOW}${BOLD}Healthy with warnings — see ⚠ items above.${RESET}"
  else
    echo -e "\n  ${GREEN}${BOLD}All checks passed. minty looks good.${RESET}"
  fi
  echo ""
}
 
# =============================================================================
#  MAIN
# =============================================================================
 
echo -e "\n${BOLD}minty Remote Access Health Check${RESET}"
echo -e "Host: ${TAILSCALE_HOSTNAME}"
echo -e "Date: $(date)"
 
check_ssh
check_firewall
check_tailscale
check_rustdesk
check_sleep
check_autologin
check_restart_policies
check_ntp
check_swap
check_system
print_summary
