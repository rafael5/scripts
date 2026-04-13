#!/usr/bin/env bash
# =============================================================================
#  minty-network-watchdog.sh
#  Version: 2.0.0
#  Target:  minty — Linux Mint 22.3 "Zena" (x86_64, bash 5.x)
#  Purpose: Periodic network health check — runs via systemd timer
#           Checks: internet, Tailscale, SSH port
#           Actions: restart Tailscale+resolved → reboot if internet/SSH lost
#
#  Changelog:
#    2.0.0  2026-04-12  Tailscale check: use interface IP instead of status text
#                       Tailscale fix: also restart systemd-resolved
#                       Reboot condition: internet/SSH only (not Tailscale alone)
#                       Boot guard: raised from 120 s to 300 s
#                       Fix: reset fail counter before rebooting (boot loop bug)
#    1.0.0  2026-04-12  Initial version
#
#  Run by:  systemd timer (minty-network-watchdog.timer)
#  Log:     /var/log/minty-network-watchdog.log
#  Requires: root (for systemctl restart, reboot)
# =============================================================================

set -uo pipefail

# =============================================================================
#  1. CONSTANTS
# =============================================================================

readonly LOG_FILE="/var/log/minty-network-watchdog.log"
readonly MAX_LOG_SIZE_KB=5120          # Rotate at 5 MB
readonly MAX_LOG_LINES_KEEP=500        # Lines to keep after rotation

readonly INTERNET_HOST="1.1.1.1"       # Ping target for internet check
readonly INTERNET_TIMEOUT=5            # Seconds for ping

readonly SSH_PORT=22
readonly SSH_TIMEOUT=3                 # Seconds for TCP connect check

readonly TAILSCALE_RESTART_WAIT=15     # Seconds to wait after restarting tailscaled
readonly UPTIME_REBOOT_GUARD=300       # Minimum uptime (seconds) before allowing reboot

readonly STATE_DIR="/var/lib/minty-network-watchdog"
readonly FAIL_COUNT_FILE="${STATE_DIR}/fail_count"
readonly MAX_FAILS=3                   # Trigger reboot after this many consecutive full-check failures

# =============================================================================
#  2. HELPERS
# =============================================================================

log() {
  local level="$1"
  shift
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  local msg="${ts} [${level}] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

rotate_log() {
  local size_kb
  size_kb=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1 || echo 0)
  size_kb="${size_kb:-0}"
  if (( size_kb > MAX_LOG_SIZE_KB )); then
    local tmp
    tmp=$(tail -n "$MAX_LOG_LINES_KEEP" "$LOG_FILE")
    echo "$tmp" > "$LOG_FILE"
    log "INFO" "Log rotated (was ${size_kb}KB)"
  fi
}

get_fail_count() {
  local raw
  raw=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
  raw=$(echo "$raw" | tr -d '[:space:]')
  echo "${raw:-0}"
}

set_fail_count() {
  mkdir -p "$STATE_DIR"
  echo "$1" > "$FAIL_COUNT_FILE"
}

inc_fail_count() {
  local count
  count=$(get_fail_count)
  set_fail_count $(( count + 1 ))
  echo $(( count + 1 ))
}

reset_fail_count() {
  set_fail_count 0
}

uptime_seconds() {
  local raw
  raw=$(awk '{print $1}' /proc/uptime 2>/dev/null || echo 0)
  # awk may return a float; truncate to integer
  printf '%.0f' "${raw:-0}"
}

# =============================================================================
#  3. CHECK FUNCTIONS
# =============================================================================

check_internet() {
  if ping -c 1 -W "$INTERNET_TIMEOUT" "$INTERNET_HOST" >/dev/null 2>&1; then
    log "INFO" "Internet: OK (${INTERNET_HOST} reachable)"
    return 0
  else
    log "WARN" "Internet: FAIL (${INTERNET_HOST} unreachable)"
    return 1
  fi
}

check_tailscale() {
  # Part 1: binary present
  if ! command -v tailscale >/dev/null 2>&1; then
    log "WARN" "Tailscale: FAIL (tailscale binary not found)"
    return 1
  fi

  # Part 2: daemon running
  if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    log "WARN" "Tailscale: FAIL (tailscaled not active)"
    return 1
  fi

  # Part 3: interface has a 100.x.x.x address.
  # Using the interface IP rather than parsing 'tailscale status' text avoids
  # false failures from transient DNS health warnings in the status output.
  local ts_ip
  ts_ip=$(ip addr show dev tailscale0 2>/dev/null | awk '/inet 100\./{print $2; exit}')
  if [[ -z "$ts_ip" ]]; then
    log "WARN" "Tailscale: FAIL (tailscale0 has no 100.x address)"
    return 1
  fi

  log "INFO" "Tailscale: OK ($ts_ip)"
  return 0
}

check_ssh_port() {
  # Check SSH port is actually accepting connections (not just systemctl is-active)
  if timeout "$SSH_TIMEOUT" bash -c "echo >/dev/tcp/127.0.0.1/${SSH_PORT}" 2>/dev/null; then
    log "INFO" "SSH port ${SSH_PORT}: OK"
    return 0
  else
    log "WARN" "SSH port ${SSH_PORT}: FAIL (not accepting connections)"
    return 1
  fi
}

# =============================================================================
#  4. FIX FUNCTIONS
# =============================================================================

fix_tailscale() {
  # Restart systemd-resolved alongside tailscaled: stale DNS config on the
  # tailscale0 interface can leave resolved in a broken state that only clears
  # when both services restart together.
  log "FIX" "Restarting systemd-resolved and tailscaled..."
  systemctl restart systemd-resolved 2>&1 | tee -a "$LOG_FILE" || true
  systemctl restart tailscaled       2>&1 | tee -a "$LOG_FILE" || true
  sleep "$TAILSCALE_RESTART_WAIT"

  # Attempt tailscale up; use TS_AUTHKEY if set
  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    log "FIX" "Running: tailscale up --authkey <key> --reset"
    tailscale up --authkey "$TS_AUTHKEY" --reset 2>&1 | tee -a "$LOG_FILE" || true
  else
    log "FIX" "Running: tailscale up"
    tailscale up 2>&1 | tee -a "$LOG_FILE" || true
  fi
}

nuclear_reboot() {
  local reason="$1"
  local uptime_s
  uptime_s=$(uptime_seconds)

  if (( uptime_s < UPTIME_REBOOT_GUARD )); then
    log "WARN" "Reboot skipped — system just started (uptime ${uptime_s}s < ${UPTIME_REBOOT_GUARD}s)"
    return
  fi

  # Snapshot system state before rebooting
  log "CRITICAL" "=== REBOOT INITIATED ==="
  log "CRITICAL" "Reason: ${reason}"
  log "CRITICAL" "Uptime: ${uptime_s}s"
  log "CRITICAL" "tailscale status: $(tailscale status 2>/dev/null | head -3 || echo 'unavailable')"
  log "CRITICAL" "systemctl --failed: $(systemctl --failed --no-legend 2>/dev/null | head -5 || echo 'unavailable')"
  # Reset counter before rebooting so a persistent failure doesn't trigger an
  # immediate reboot on the first check of the next boot (boot loop fix).
  reset_fail_count
  log "CRITICAL" "Rebooting now..."

  /sbin/reboot
}

# =============================================================================
#  5. MAIN LOGIC
# =============================================================================

main() {
  # Ensure log file and state dir exist
  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"
  rotate_log

  log "INFO" "=== Network watchdog run start ==="

  local internet_ok=0
  local tailscale_ok=0
  local ssh_ok=0

  check_internet  && internet_ok=1  || true
  check_tailscale && tailscale_ok=1 || true
  check_ssh_port  && ssh_ok=1       || true

  # --- Tailscale fix ---
  if (( tailscale_ok == 0 )); then
    log "FIX" "Tailscale check failed — attempting restart"
    fix_tailscale

    # Recheck after fix
    if check_tailscale; then
      log "INFO" "Tailscale recovered after restart"
      tailscale_ok=1
    else
      log "WARN" "Tailscale still down after restart attempt"
    fi
  fi

  # --- Determine overall health ---
  # Tailscale is a soft dependency: failure triggers service recovery but never
  # a reboot.  Only internet or SSH loss counts toward the reboot threshold.
  local critical_ok=1
  [[ "$internet_ok" -eq 0 ]] && critical_ok=0
  [[ "$ssh_ok"      -eq 0 ]] && critical_ok=0

  if (( critical_ok == 1 )); then
    log "INFO" "All critical checks passed — resetting fail counter"
    reset_fail_count
  else
    local fails
    fails=$(inc_fail_count)
    log "WARN" "Critical check(s) failed — consecutive fail count: ${fails}/${MAX_FAILS}"

    if (( fails >= MAX_FAILS )); then
      nuclear_reboot "Network checks failed ${fails} consecutive times (internet=${internet_ok} tailscale=${tailscale_ok} ssh=${ssh_ok})"
    else
      log "INFO" "Will retry at next timer interval (${fails}/${MAX_FAILS} before reboot)"
    fi
  fi

  log "INFO" "=== Network watchdog run complete ==="
}

main "$@"
