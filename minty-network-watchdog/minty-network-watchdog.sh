#!/usr/bin/env bash
# =============================================================================
#  minty-network-watchdog.sh
#  Version: 2.2.0
#  Target:  minty — Linux Mint 22.3 "Zena" (x86_64, bash 5.x)
#
#  Purpose
#  Periodic network health watchdog for minty. Checks internet connectivity,
#  Tailscale VPN, SSH port reachability, and RustDesk rendezvous connection.
#  Applies targeted fixes and escalates to reboot only after repeated critical
#  failures — keeping the machine accessible for remote administration.
#
#  Design
#  Runs as root via systemd timer every 5 minutes. Linear check sequence with
#  escalating fix actions. Fail counter persists across runs in STATE_DIR;
#  reboot only triggers after 3 consecutive critical failures (internet + SSH
#  both lost). Boot guard prevents reboot if uptime < 300 s. Log rotates at
#  5 MB. All checks are independent — Tailscale failure does not trigger
#  reboot alone.
#
#  Features
#  - Internet check: ping 1.1.1.1 with configurable timeout
#  - SSH check: TCP connect to localhost:22
#  - Tailscale check: interface IP presence on tailscale0 (no text parsing)
#  - Tailscale fix: tailscaled restart (step 1); systemd-resolved only if
#    tailscale0 still has no 100.x address (step 2 — avoids DNS disruption)
#  - RustDesk check: detects --server stuck in exponential backoff by
#    checking for established TCP connection to rendezvous port 21116;
#    kills stuck process so --service respawns it fresh
#  - Fail counter: resets on any success; reboot after 3 consecutive failures
#  - Boot guard: no reboot if uptime < 300 s
#  - Log rotation at 5 MB (keeps last 500 lines)
#
#  Checks and Actions
#  check_internet()    Ping 1.1.1.1 — critical for reboot escalation
#  check_ssh()         TCP connect to localhost:22 — critical for reboot
#  check_tailscale()   Interface IP on tailscale0; fix: restart tailscaled
#  check_rustdesk()    Rendezvous TCP connection; fix: kill stuck --server
#  fix_tailscale()     Two-step restart: tailscaled first, resolved if needed
#  maybe_reboot()      Reboot if fail_count ≥ 3 and uptime > boot guard
#
#  Changelog
#  2.2.0  2026-04-13  Add check_rustdesk: detects --server backoff by port
#                     21116 TCP check; kills stuck process for fresh respawn
#  2.1.0  2026-04-13  fix_tailscale: tailscaled-only first; systemd-resolved
#                     only as step-2 escalation to avoid DNS disruption
#  2.0.0  2026-04-12  Tailscale: interface IP check (not status text parsing)
#                     Reboot condition: internet+SSH only (not Tailscale alone)
#                     Boot guard raised to 300 s; fix fail-counter boot loop
#  1.0.0  2026-04-12  Initial version
#
#  Run by:  systemd timer (minty-network-watchdog.timer) — every 5 minutes
#  Log:     /var/log/minty-network-watchdog.log
#  Requires: root (systemctl restart, reboot)
#  Deploy:   cd ~/scripts/minty-network-watchdog && sudo bash install.sh
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
  # Step 1: restart tailscaled only.
  # Restarting tailscaled alone is enough for most flaps and does NOT touch
  # systemd-resolved, so DNS-dependent services (e.g. RustDesk) are unaffected.
  log "FIX" "Restarting tailscaled (step 1)..."
  systemctl restart tailscaled 2>&1 | tee -a "$LOG_FILE" || true
  sleep "$TAILSCALE_RESTART_WAIT"

  # Attempt tailscale up; use TS_AUTHKEY if set
  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    log "FIX" "Running: tailscale up --authkey <key> --reset"
    tailscale up --authkey "$TS_AUTHKEY" --reset 2>&1 | tee -a "$LOG_FILE" || true
  else
    log "FIX" "Running: tailscale up"
    tailscale up 2>&1 | tee -a "$LOG_FILE" || true
  fi

  # Step 2: if tailscale0 still has no 100.x address, escalate by restarting
  # systemd-resolved as well.  Stale DNS config on tailscale0 can leave
  # resolved in a broken state that only clears when both restart together.
  # This causes a brief DNS outage (~2 s), so it is a last resort.
  local ts_ip
  ts_ip=$(ip addr show dev tailscale0 2>/dev/null | awk '/inet 100\./{print $2; exit}')
  if [[ -z "$ts_ip" ]]; then
    log "FIX" "tailscale0 still no 100.x address — restarting systemd-resolved (step 2)..."
    systemctl restart systemd-resolved 2>&1 | tee -a "$LOG_FILE" || true
    sleep "$TAILSCALE_RESTART_WAIT"
  fi
}

# =============================================================================
#  4b. RUSTDESK CHECK / FIX
# =============================================================================

# Minimum seconds the --server process must have been running before we act.
# A freshly spawned process needs time to connect; don't kill it too soon.
readonly RUSTDESK_CONN_GRACE=60

check_rustdesk() {
  # Skip entirely if the service isn't installed or active.
  if ! systemctl is-active --quiet rustdesk 2>/dev/null; then
    log "INFO" "RustDesk: service not active — skipping"
    return 0
  fi

  # Find the --server child process (runs as the desktop user, not root).
  local server_pid
  server_pid=$(pgrep -fx ".*/rustdesk --server" 2>/dev/null | head -1)
  if [[ -z "$server_pid" ]]; then
    log "WARN" "RustDesk: service active but --server process not found"
    return 1
  fi

  # How long has this --server instance been alive?
  local proc_start elapsed
  proc_start=$(stat -c %Y /proc/"$server_pid" 2>/dev/null || echo 0)
  elapsed=$(( $(date +%s) - proc_start ))
  if (( elapsed < RUSTDESK_CONN_GRACE )); then
    log "INFO" "RustDesk: --server (pid=${server_pid}) started ${elapsed}s ago — within grace period, skipping"
    return 0
  fi

  # An established TCP connection to port 21116 means the --server is
  # registered with the rendezvous server and RustDesk shows "ready".
  if ss -tn state established 2>/dev/null | awk '{print $4}' | grep -q ':21116$'; then
    log "INFO" "RustDesk: OK (rendezvous connection established)"
    return 0
  fi

  # No connection after the grace period — the process is stuck in backoff.
  # Kill it; the --service parent respawns it immediately and the fresh
  # process connects within seconds.
  log "FIX" "RustDesk: --server (pid=${server_pid}) has no rendezvous connection after ${elapsed}s — killing to reset backoff"
  kill -9 "$server_pid" 2>/dev/null || true
  return 1
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

  # --- RustDesk fix ---
  # Independent of the Tailscale/internet checks — runs every cycle.
  # No effect on the reboot counter; purely a soft self-healing action.
  check_rustdesk || true

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
