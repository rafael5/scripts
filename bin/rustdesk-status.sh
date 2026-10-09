#!/usr/bin/env bash
# =============================================================================
#  rustdesk-status.sh
#  Version: 1.4.0
#  Target:  minty — Linux Mint 22.3 with RustDesk and minty-network-watchdog
#
#  Purpose
#  RustDesk diagnostic and self-healing tool. Provides a status dashboard,
#  comprehensive diagnostic check, rendezvous server port tests, live log
#  access, and fix actions — including resetting the --server exponential
#  backoff that causes the persistent "not ready" state.
#
#  Clients connect to minty by its tailnet address, through RustDesk's direct
#  IP access on port 21118 (enabled 2026-09-30), so the public rendezvous
#  server is no longer needed to reach it. The direct-access checks are the
#  ones that decide whether minty is reachable; rendezvous problems are
#  reported as warnings, for connections by RustDesk ID only.
#
#  Design
#  Command-dispatch script: a single entry point with subcommands dispatched
#  via a case statement. Each command is an isolated cmd_* function. Core
#  state queries (get_server_pid, rendezvous_connected, rendezvous_server_up,
#  direct_*, proc_age_seconds) are shared helpers used by multiple commands.
#
#  The key insight: RustDesk's --server process uses exponential backoff after
#  connection failures; the backoff can reach hours. The fix is to kill only
#  the --server child — the --service parent respawns it immediately with a
#  fresh backoff state. The reset command targets the process by user rafael
#  to distinguish the actual binary from the root-owned sudo wrapper. Killing
#  it also ends every live session, so reset refuses while one is open on the
#  direct-access port.
#
#  Features
#  - Status dashboard: one line each for service, processes, direct access,
#    rendezvous and watchdog; a fix hint only under a line that is not green
#  - Full diagnostic: one line per area, pass/warn/fail counted per
#    sub-check, a fix hint only under a line that is not green
#  - Direct access: option on, listening on 21118, accepting on the tailnet
#    address, live session count
#  - Rendezvous server port tests (21115, 21116, 21117) with ICMP, on one line
#  - Recent journal lines + watchdog log entries
#  - Backoff reset: kills stuck --server, waits for respawn, confirms connection
#  - Full service restart (requires sudo)
#  - Watchdog: timer + fail counter, then the last N runs, one line each
#  - Distinguishes backoff, server outage, and network failure as causes
#
#  Functions
#  get_server_pid          pgrep for --server process owned by user rafael
#  rendezvous_connected    log-freshness check for UDP rendezvous heartbeat
#  rendezvous_server_up    nc TCP check to rs-ny.rustdesk.com:21116
#  direct_access_enabled   direct-server = 'Y' in the RustDesk config
#  direct_port_listening   ss: a listener on the direct-access port
#  direct_port_reachable   nc TCP check to the tailnet address:direct port
#  direct_sessions         Count of established sessions on the direct port
#  tailnet_ip              This host's Tailscale IPv4 address
#  proc_age_seconds pid    Seconds since the process started (ps etimes)
#  human_age seconds       Format seconds as Xs, Xm Ys, Xh Ym or Xd Yh
#  cmd_status              Dashboard: service, processes, connection, watchdog
#  cmd_check               Full pass/warn/fail diagnostic
#  cmd_server              Port tests: ICMP + TCP 21115/21116/21117
#  cmd_logs [N]            Journal + watchdog log tail
#  cmd_reset               Kill stuck --server, wait for respawn, confirm
#  cmd_restart             sudo systemctl restart rustdesk + connection wait
#  cmd_watchdog [N]        Timer + fail counter, last N runs one line each
#  cmd_help                Usage and flow documentation
#
#  Use
#  rustdesk-status.sh              # status dashboard (default)
#  rustdesk-status.sh check        # full diagnostic
#  rustdesk-status.sh reset        # fix --server backoff (most common)
#  rustdesk-status.sh server       # test rendezvous server ports
#  rustdesk-status.sh logs [N]     # recent journal + watchdog entries
#  rustdesk-status.sh watchdog [N] # timer state + last N runs (default 10)
#  rustdesk-status.sh restart      # full service restart (requires sudo)
#  Run as normal user; sudo required only for 'restart'
#  RUSTDESK_DIRECT_PORT overrides the direct-access port (default 21118)
# =============================================================================

set -euo pipefail

# =============================================================================
#  CONSTANTS
# =============================================================================

readonly RENDEZVOUS_HOST="rs-ny.rustdesk.com"
readonly RENDEZVOUS_PORT=21116
readonly NAT_TEST_PORT=21115
readonly RELAY_PORT=21117
readonly DIRECT_PORT="${RUSTDESK_DIRECT_PORT:-21118}"  # direct IP access, reached over Tailscale
readonly RUSTDESK_CONFIG="$HOME/.config/rustdesk/RustDesk2.toml"
readonly RUSTDESK_SERVER_LOG="$HOME/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log"
readonly WATCHDOG_LOG="/var/log/minty-network-watchdog.log"
readonly SERVER_CONN_GRACE=60        # seconds before declaring --server stuck
readonly RENDEZVOUS_LOG_MAX_AGE=120  # max age of most recent rendezvous heartbeat log line
readonly NC_TIMEOUT=4                # seconds for port checks
readonly RS_PORTS=("${NAT_TEST_PORT}:nat" "${RENDEZVOUS_PORT}:register" "${RELAY_PORT}:relay")

# =============================================================================
#  COLORS / OUTPUT HELPERS
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ok()      { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
fail()    { echo -e "  ${RED}✘${RESET}  $*"; }
info()    { echo -e "  ${CYAN}·${RESET}  $*"; }
detail()  { echo -e "  ${DIM}    $*${RESET}"; }
section() { echo -e "\n${BOLD}━━━ $* ${RESET}"; }
label()   { printf '%-12s' "$1"; }  # fixed-width row label for the dashboard
join_dot() { local s; s=$(printf '%s · ' "$@"); echo "${s% · }"; }  # "a · b · c"
hline()   { echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

svc_active() {
  [[ "$(systemctl is-active "$1" 2>/dev/null)" == "active" ]]
}

# =============================================================================
#  CORE STATE FUNCTIONS (used by multiple commands)
# =============================================================================

# Returns the PID of the rustdesk --server process (the actual binary, not the
# sudo wrapper that spawns it).  The real process runs as the desktop user.
get_server_pid() {
  pgrep -u rafael -fx ".*/rustdesk --server" 2>/dev/null | head -1 || true
}

# Returns 0 if a recent rendezvous heartbeat appears in the --server log.
# RustDesk's rendezvous is UDP, so there's no TCP ESTABLISHED state to check.
# The --server writes a "Latency of rs-ny...:21116" DEBUG line each minute
# while it's maintaining the UDP rendezvous connection; absence of that line
# for RENDEZVOUS_LOG_MAX_AGE seconds means the mediator has stopped heartbeating.
rendezvous_connected() {
  [[ -r "$RUSTDESK_SERVER_LOG" ]] || return 1
  local last_ts now_ts age
  last_ts=$(grep -a "Latency of ${RENDEZVOUS_HOST}:${RENDEZVOUS_PORT}" "$RUSTDESK_SERVER_LOG" 2>/dev/null \
    | tail -1 | sed -n 's/^\[\([0-9-]* [0-9:]*\)\..*/\1/p')
  [[ -n "$last_ts" ]] || return 1
  last_ts=$(date -d "$last_ts" +%s 2>/dev/null) || return 1
  now_ts=$(date +%s)
  age=$(( now_ts - last_ts ))
  (( age <= RENDEZVOUS_LOG_MAX_AGE ))
}

# Prints the age in seconds of the most recent rendezvous heartbeat log line,
# or empty string if none found.
rendezvous_heartbeat_age() {
  [[ -r "$RUSTDESK_SERVER_LOG" ]] || return 0
  local last_ts
  last_ts=$(grep -a "Latency of ${RENDEZVOUS_HOST}:${RENDEZVOUS_PORT}" "$RUSTDESK_SERVER_LOG" 2>/dev/null \
    | tail -1 | sed -n 's/^\[\([0-9-]* [0-9:]*\)\..*/\1/p')
  [[ -n "$last_ts" ]] || return 0
  last_ts=$(date -d "$last_ts" +%s 2>/dev/null) || return 0
  echo $(( $(date +%s) - last_ts ))
}

# Returns 0 if the rendezvous server TCP port is accepting connections.
rendezvous_server_up() {
  nc -z -w "$NC_TIMEOUT" "$RENDEZVOUS_HOST" "$RENDEZVOUS_PORT" 2>/dev/null
}

# Returns 0 if direct IP access is switched on. The root --service holds the
# option and copies it into the user's config, so the user's copy shows it;
# editing that copy by hand does not stick (set it with
# `sudo rustdesk --option direct-server Y`).
direct_access_enabled() {
  grep -qE "^direct-server = 'Y'" "$RUSTDESK_CONFIG" 2>/dev/null
}

# Returns 0 if something is listening on the direct-access port.
direct_port_listening() {
  [[ -n "$(ss -Hltn "sport = :${DIRECT_PORT}" 2>/dev/null)" ]]
}

# Prints this host's Tailscale IPv4 address, or nothing.
tailnet_ip() {
  tailscale ip -4 2>/dev/null | head -1 || true
}

# Returns 0 if the direct-access port accepts a TCP connection on the tailnet
# address. From this host the connection stays local, so this proves the
# listener answers on that address; it does not test the firewall.
direct_port_reachable() {
  local ip
  ip=$(tailnet_ip)
  [[ -n "$ip" ]] && nc -z -w "$NC_TIMEOUT" "$ip" "$DIRECT_PORT" 2>/dev/null
}

# Prints the number of established sessions on the direct-access port.
direct_sessions() {
  ss -Htn state established "sport = :${DIRECT_PORT}" 2>/dev/null | wc -l
}

# Seconds since the given process started, from the start time the kernel
# records (ps etimes). Not the /proc/<pid> directory's mtime: that is when the
# directory was first looked up, which can be long after the start (measured
# 2026-09-30: 33m reported for a process 53m old).
proc_age_seconds() {
  local pid="$1"
  local age
  age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
  echo "${age:-0}"
}

# Human-readable age string from seconds.
human_age() {
  local s="$1"
  if   (( s < 60  )); then echo "${s}s"
  elif (( s < 3600 )); then echo "$(( s / 60 ))m $(( s % 60 ))s"
  elif (( s < 86400 )); then echo "$(( s / 3600 ))h $(( (s % 3600) / 60 ))m"
  else                      echo "$(( s / 86400 ))d $(( (s % 86400) / 3600 ))h"
  fi
}

# =============================================================================
#  STATUS DASHBOARD  (default / 'status')
# =============================================================================

cmd_status() {
  local ts_ip server_pid sessions
  ts_ip=$(tailnet_ip)
  server_pid=$(get_server_pid)
  sessions=$(direct_sessions)

  echo -e "${BOLD}RustDesk — $(hostname)${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M')${RESET}"

  # --- Service ---
  local restart_pol
  restart_pol=$(systemctl show rustdesk --property=Restart --value 2>/dev/null || true)
  if svc_active rustdesk; then
    ok "$(label service)active · restart=${restart_pol}"
  else
    fail "$(label service)NOT active"
    detail "fix: sudo systemctl start rustdesk"
  fi

  # --- Processes: role and age of each, e.g. "service 7d 20h · server 37m 23s" ---
  # Match only processes whose executable path contains "rustdesk" (field 2).
  # This avoids false matches from scripts with "rustdesk" in their arguments.
  local procs line pid role parts=()
  procs=$(ps -eo pid,cmd --no-headers 2>/dev/null | awk '$2 ~ /[r]ustdesk/' || true)
  if [[ -z "$procs" ]]; then
    fail "$(label processes)none running"
    detail "fix: sudo systemctl restart rustdesk"
  else
    while read -r pid _ role _; do
      parts+=("${role#--} $(human_age "$(proc_age_seconds "$pid")")")
    done <<< "$procs"
    info "$(label processes)$(join_dot "${parts[@]}")"
  fi

  # --- Direct access (tailnet) ---
  if ! direct_access_enabled; then
    fail "$(label direct)OFF — clients cannot connect by tailnet address"
    detail "fix: sudo rustdesk --option direct-server Y"
  elif ! direct_port_listening; then
    fail "$(label direct)option on, but nothing listening on :${DIRECT_PORT}"
    detail "fix: rustdesk-status.sh restart"
  elif ! direct_port_reachable; then
    fail "$(label direct)not answering on ${ts_ip:-no Tailscale IP}:${DIRECT_PORT} · ${sessions} sessions"
    detail "check: tailscale status"
  else
    ok "$(label direct)${ts_ip}:${DIRECT_PORT} accepting · ${sessions} sessions"
  fi

  # --- Rendezvous (ID connections only) ---
  if [[ -z "$server_pid" ]]; then
    fail "$(label rendezvous)--server not running"
    detail "fix: rustdesk-status.sh reset, then restart if that fails"
  else
    local age
    age=$(proc_age_seconds "$server_pid")
    if rendezvous_connected; then
      ok "$(label rendezvous)connected · heartbeat $(rendezvous_heartbeat_age)s ago"
    elif (( age < SERVER_CONN_GRACE )); then
      warn "$(label rendezvous)not yet connected · --server ${age}s old, grace ${SERVER_CONN_GRACE}s"
    elif rendezvous_server_up; then
      warn "$(label rendezvous)not registered, public server is up · --server $(human_age "$age") old"
      detail "fix: rustdesk-status.sh reset  (ID connections only; tailnet access unaffected)"
    else
      warn "$(label rendezvous)public server ${RENDEZVOUS_HOST} unreachable — outage, nothing to fix here"
      detail "ID connections only; tailnet access unaffected"
    fi
  fi

  # --- Watchdog ---
  if systemctl is-active --quiet minty-network-watchdog.timer 2>/dev/null; then
    local next_run
    next_run=$(systemctl list-timers minty-network-watchdog.timer --no-pager --no-legend 2>/dev/null \
      | awk 'NR==1{print $3}' || true)
    ok "$(label watchdog)timer active${next_run:+ · next ${next_run}}"
  else
    warn "$(label watchdog)timer NOT active"
    detail "fix: cd ~/scripts/minty-network-watchdog && sudo bash install.sh"
  fi
}

# =============================================================================
#  COMPREHENSIVE DIAGNOSTIC  ('check')
# =============================================================================

cmd_check() {
  local pass=0 warn=0 fail=0
  # One row per area: each sub-check adds a fragment and counts toward the
  # summary; the row takes the symbol of its worst fragment.
  local row_state=0 row_parts=() row_fixes=()

  _pass() { row_parts+=("$1"); (( pass++ )) || true; }
  _warn() { row_parts+=("${YELLOW}$1${RESET}"); (( warn++ )) || true
            row_state=$(( row_state > 1 ? row_state : 1 )); }
  _fail() { row_parts+=("${RED}$1${RESET}"); (( fail++ )) || true; row_state=2; }
  _note() { row_parts+=("$1"); }     # shown, not counted
  _fix()  { row_fixes+=("$1"); }
  _row()  {                          # print the row, then each distinct fix
    local text f
    text="$(label "$1")$(join_dot "${row_parts[@]}")"
    case $row_state in 0) ok "$text" ;; 1) warn "$text" ;; *) fail "$text" ;; esac
    printf '%s\n' "${row_fixes[@]}" | awk 'NF && !seen[$0]++' \
      | while IFS= read -r f; do detail "$f"; done
    row_state=0; row_parts=(); row_fixes=()
  }

  local deploy_fix="fix: cd ~/scripts/minty-network-watchdog && sudo bash install.sh  (deploys, then starts the timer)"

  echo -e "${BOLD}RustDesk check — $(hostname)${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M')${RESET}"

  # --- Service ---
  if svc_active rustdesk; then
    _pass "active"
  else
    _fail "NOT active"; _fix "fix: sudo systemctl start rustdesk"
  fi

  local enabled
  enabled=$(systemctl is-enabled rustdesk 2>/dev/null || echo "unknown")
  if [[ "$enabled" == "enabled" ]]; then
    _pass "enabled"
  else
    _fail "not enabled (${enabled})"; _fix "fix: sudo systemctl enable rustdesk"
  fi

  local restart_pol
  restart_pol=$(systemctl show rustdesk --property=Restart --value 2>/dev/null || true)
  case "$restart_pol" in
    on-failure|always|on-abnormal) _pass "restart=${restart_pol}" ;;
    *)
      _warn "restart=${restart_pol}, won't auto-recover from crashes"
      _fix "fix: sudo systemctl edit rustdesk  # add: [Service] Restart=on-failure"
      ;;
  esac
  _row service

  # --- Config ---
  if [[ -f "$RUSTDESK_CONFIG" ]]; then
    local rs_server nat_type
    rs_server=$(grep 'rendezvous_server' "$RUSTDESK_CONFIG" 2>/dev/null | cut -d"'" -f2 || true)
    nat_type=$(grep 'nat_type' "$RUSTDESK_CONFIG" 2>/dev/null | awk '{print $3}' || true)
    _pass "found"
    _note "server ${rs_server:-unknown}"
    _note "NAT type ${nat_type:-unknown}"
  else
    _warn "not found at ${RUSTDESK_CONFIG}"
    _fix "fix: launch the RustDesk GUI once to create it, or look in ~/.config/rustdesk/"
  fi
  _row config

  # --- Processes ---
  local service_pid server_pid tray_pid
  service_pid=$(pgrep -fx "/usr/bin/rustdesk --service" 2>/dev/null | head -1 || true)
  server_pid=$(get_server_pid)
  tray_pid=$(pgrep -fx ".*/rustdesk --tray" 2>/dev/null | head -1 || true)

  if [[ -n "$service_pid" ]]; then
    _pass "service $(human_age "$(proc_age_seconds "$service_pid")")"
  else
    _fail "service NOT running"; _fix "fix: sudo systemctl restart rustdesk"
  fi

  if [[ -n "$server_pid" ]]; then
    _pass "server $(human_age "$(proc_age_seconds "$server_pid")")"
  else
    _fail "server NOT running"; _fix "fix: rustdesk-status.sh reset, then restart if that fails"
  fi

  if [[ -n "$tray_pid" ]]; then
    _note "tray $(human_age "$(proc_age_seconds "$tray_pid")")"
  else
    _note "no tray (normal without a desktop session)"
  fi
  _row processes

  # --- Direct access (tailnet) ---
  if direct_access_enabled; then
    _pass "option on"
  else
    _fail "option OFF"; _fix "fix: sudo rustdesk --option direct-server Y"
  fi

  if direct_port_listening; then
    _pass "listening"
  else
    _fail "nothing listening on :${DIRECT_PORT}"; _fix "fix: rustdesk-status.sh restart"
  fi

  local ts_ip
  ts_ip=$(tailnet_ip)
  if [[ -z "$ts_ip" ]]; then
    _fail "no Tailscale IPv4 address"; _fix "check: tailscale status"
  elif direct_port_reachable; then
    _pass "${ts_ip}:${DIRECT_PORT} answers locally"   # from this host; the firewall is not tested
  else
    _fail "not answering on ${ts_ip}:${DIRECT_PORT}"; _fix "check: tailscale status"
  fi
  _note "$(direct_sessions) sessions"
  _row direct

  # --- Rendezvous server ports ---
  # Warnings, not failures: only connections by RustDesk ID need the public
  # server; connections by tailnet address do not.
  local port_desc port name
  for port_desc in "${RS_PORTS[@]}"; do
    port="${port_desc%%:*}"
    name="${port_desc##*:}"
    if nc -z -w "$NC_TIMEOUT" "$RENDEZVOUS_HOST" "$port" 2>/dev/null; then
      _pass "${port} ${name} open"
    else
      _warn "${port} ${name} unreachable"
      _fix "public server ${RENDEZVOUS_HOST}: no local fix; ID connections only"
    fi
  done
  _row "rs ports"

  # --- Rendezvous connection state ---
  if [[ -z "$server_pid" ]]; then
    _fail "cannot evaluate, --server not running"
  elif rendezvous_connected; then
    _pass "connected · heartbeat $(rendezvous_heartbeat_age)s ago"
  else
    local age
    age=$(proc_age_seconds "$server_pid")
    if (( age < SERVER_CONN_GRACE )); then
      _warn "not yet connected · --server ${age}s old, grace ${SERVER_CONN_GRACE}s"
    elif rendezvous_server_up; then
      _warn "not registered for $(human_age "$age"), public server is up"
      _fix "fix: rustdesk-status.sh reset  (ID connections only; refused while a session is live)"
    else
      _warn "not connected, public server unreachable — outage, nothing to fix here"
    fi
  fi
  _row rendezvous

  # --- Watchdog ---
  if systemctl is-active --quiet minty-network-watchdog.timer 2>/dev/null; then
    _pass "timer active"
  else
    _fail "timer NOT active, auto-recovery off"; _fix "$deploy_fix"
  fi

  # Check that the deployed watchdog checks the direct-access port (v2.3.0+).
  # The deployed file is root:root mode 750, so fall back to the source copy
  # under ~/scripts/ when it isn't readable by the current user.
  local deployed="/usr/local/sbin/minty-network-watchdog.sh"
  local source_copy="$HOME/scripts/minty-network-watchdog/minty-network-watchdog.sh"
  local scan=""
  if [[ -r "$deployed" ]]; then
    scan="$deployed"
  elif [[ -f "$deployed" && -r "$source_copy" ]]; then
    scan="$source_copy"
  fi
  if [[ ! -f "$deployed" ]]; then
    _warn "not deployed at ${deployed}"; _fix "$deploy_fix"
  elif [[ -z "$scan" ]]; then
    _warn "can't read ${deployed} or its source, direct-port check unverified"
  elif [[ "$scan" == "$source_copy" && "$source_copy" -nt "$deployed" ]]; then
    # The source copy only stands in for the deployed one if it isn't newer.
    _warn "deployed copy older than its source"; _fix "$deploy_fix"
  elif grep -q "RUSTDESK_DIRECT_PORT" "$scan" 2>/dev/null; then
    if [[ "$scan" == "$source_copy" ]]; then
      _pass "checks direct port (read from source copy)"
    else
      _pass "checks direct port"
    fi
  elif grep -q "check_rustdesk" "$scan" 2>/dev/null; then
    _warn "check_rustdesk predates v2.3.0, kills --server when unregistered"; _fix "$deploy_fix"
  else
    _warn "deployed copy has no check_rustdesk"; _fix "$deploy_fix"
  fi

  local fail_count_file="/var/lib/minty-network-watchdog/fail_count"
  if [[ -f "$fail_count_file" ]]; then
    local fail_count
    fail_count=$(cat "$fail_count_file" 2>/dev/null | tr -d '[:space:]')
    if [[ "$fail_count" -eq 0 ]]; then
      _pass "fail counter 0"
    else
      _warn "fail counter ${fail_count}/3"
    fi
  fi
  _row watchdog

  # --- Summary ---
  local counts="${pass} pass · ${warn} warn · ${fail} fail"
  if   (( fail > 0 )); then echo -e "  ${RED}${BOLD}Issues found${RESET}  ${counts}"
  elif (( warn > 0 )); then echo -e "  ${YELLOW}${BOLD}Healthy with warnings${RESET}  ${counts}"
  else                      echo -e "  ${GREEN}${BOLD}All checks passed${RESET}  ${counts}"
  fi
}

# =============================================================================
#  SERVER PORT TEST  ('server')
# =============================================================================

cmd_server() {
  local ip
  ip=$(getent hosts "$RENDEZVOUS_HOST" 2>/dev/null | awk '{print $1}' | head -1 \
    || dig +short "$RENDEZVOUS_HOST" 2>/dev/null | head -1 \
    || true)
  echo -e "${BOLD}RustDesk server — ${RENDEZVOUS_HOST} (${ip:-unresolved})${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M')${RESET}"

  if ping -c 1 -W 3 "$RENDEZVOUS_HOST" >/dev/null 2>&1; then
    ok "$(label ping)reachable"
  else
    warn "$(label ping)no response (may be filtered)"
  fi

  local port_desc port name parts=() closed=0
  for port_desc in "${RS_PORTS[@]}"; do
    port="${port_desc%%:*}"
    name="${port_desc##*:}"
    if nc -z -w "$NC_TIMEOUT" "$RENDEZVOUS_HOST" "$port" 2>/dev/null; then
      parts+=("${port} ${name} open")
    else
      parts+=("${RED}${port} ${name} unreachable${RESET}"); closed=1
    fi
  done
  if (( closed )); then
    fail "$(label ports)$(join_dot "${parts[@]}")"
  else
    ok "$(label ports)$(join_dot "${parts[@]}")"
  fi
}

# =============================================================================
#  LOGS  ('logs [N]')
# =============================================================================

cmd_logs() {
  local n="${1:-30}"
  echo -e "\n${BOLD}RustDesk Journal — last ${n} lines${RESET}"
  hline
  journalctl -u rustdesk --no-pager -n "$n" 2>/dev/null \
    | grep -v "flutter:\|gdk_device\|pam_unix\|session opened\|session closed" \
    || echo "  (no journal entries)"
  echo ""

  if [[ -f "$WATCHDOG_LOG" ]]; then
    echo -e "${BOLD}Watchdog Log — last 10 RustDesk entries${RESET}"
    hline
    grep -i "rustdesk" "$WATCHDOG_LOG" 2>/dev/null | tail -10 \
      || echo "  (no RustDesk entries in watchdog log)"
    echo ""
  fi
}

# =============================================================================
#  RESET --server BACKOFF  ('reset')
# =============================================================================

cmd_reset() {
  echo -e "\n${BOLD}Reset RustDesk --server Backoff${RESET}"
  echo ""

  if ! svc_active rustdesk; then
    fail "rustdesk.service is not active — nothing to reset"
    echo ""
    return 1
  fi

  local server_pid
  server_pid=$(get_server_pid)

  if [[ -z "$server_pid" ]]; then
    fail "--server process not found"
    echo ""
    return 1
  fi

  local age
  age=$(proc_age_seconds "$server_pid")
  info "Found --server PID ${server_pid} (running $(human_age "$age"))"

  if rendezvous_connected; then
    ok "Already connected to rendezvous server — reset not needed"
    echo ""
    return 0
  fi

  # Killing --server ends every session it holds.
  local sessions
  sessions=$(direct_sessions)
  if (( sessions > 0 )); then
    fail "Refusing: ${sessions} live session(s) on :${DIRECT_PORT} would be cut"
    info "Reset only matters for connections by RustDesk ID; tailnet connections do not need it"
    echo ""
    return 1
  fi

  info "Killing PID ${server_pid} — the --service parent will respawn it immediately"
  if kill -9 "$server_pid" 2>/dev/null; then
    ok "Killed PID ${server_pid}"
  else
    fail "Could not kill PID ${server_pid} — may need sudo"
    echo ""
    return 1
  fi

  # Brief pause then check
  local attempts=0 new_pid=""
  while (( attempts < 8 )); do
    (( ++attempts ))
    new_pid=$(get_server_pid)
    if [[ -n "$new_pid" && "$new_pid" != "$server_pid" ]]; then
      ok "New --server PID ${new_pid} spawned"
      break
    fi
    sleep 0.5
  done

  new_pid=$(get_server_pid)
  if [[ -z "$new_pid" ]]; then
    warn "No new --server process yet — may take a moment"
    echo ""
    return 0
  fi

  # Wait up to ~5 seconds for connection
  local connected=false
  for _ in 1 2 3 4 5; do
    if rendezvous_connected; then
      connected=true
      break
    fi
    sleep 1
  done

  if $connected; then
    local hb_age
    hb_age=$(rendezvous_heartbeat_age)
    ok "Connected: UDP ${RENDEZVOUS_HOST}:${RENDEZVOUS_PORT}, heartbeat ${hb_age}s ago"
    ok "RustDesk should now show READY"
  else
    if rendezvous_server_up; then
      warn "New process spawned but not connected yet — may still be initializing"
    else
      warn "New process spawned but rendezvous server appears to be down"
      info "Will connect automatically once the server recovers"
    fi
  fi
  echo ""
}

# =============================================================================
#  RESTART SERVICE  ('restart')
# =============================================================================

cmd_restart() {
  echo -e "\n${BOLD}Restart RustDesk Service${RESET}"
  echo ""
  info "Running: sudo systemctl restart rustdesk"
  if sudo systemctl restart rustdesk; then
    ok "Service restarted"
    info "Waiting for --server to connect..."
    local new_pid=""
    for _ in 1 2 3 4 5 6 7 8; do
      new_pid=$(get_server_pid)
      [[ -n "$new_pid" ]] && break
      sleep 1
    done
    if [[ -n "$new_pid" ]]; then
      ok "--server PID ${new_pid} running"
    fi
    if rendezvous_connected; then
      ok "Connected to rendezvous server — RustDesk is READY"
    else
      info "Not connected yet — run 'rustdesk-status.sh status' in a moment to recheck"
    fi
  else
    fail "sudo systemctl restart rustdesk failed"
  fi
  echo ""
}

# =============================================================================
#  WATCHDOG LOG  ('watchdog')
# =============================================================================

cmd_watchdog() {
  local n="${1:-10}"
  echo -e "${BOLD}Watchdog — last ${n} runs${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M')${RESET}"

  local fc next_run
  fc=$(cat /var/lib/minty-network-watchdog/fail_count 2>/dev/null | tr -d '[:space:]' || true)
  if systemctl is-active --quiet minty-network-watchdog.timer 2>/dev/null; then
    next_run=$(systemctl list-timers minty-network-watchdog.timer --no-pager --no-legend 2>/dev/null \
      | awk 'NR==1{print $3}' || true)
    ok "$(label timer)active${next_run:+ · next ${next_run}} · fail counter ${fc:-0}/3"
  else
    warn "$(label timer)NOT active · fail counter ${fc:-0}/3"
    detail "fix: cd ~/scripts/minty-network-watchdog && sudo bash install.sh"
  fi

  if [[ ! -r "$WATCHDOG_LOG" ]]; then
    warn "$(label log)cannot read ${WATCHDOG_LOG}"
    return
  fi

  # One row per run: "Name: OK (...)" lines become the names of the checks
  # that passed; a FAIL is shown inline in full; any other line (fix actions,
  # warnings, command output) prints beneath its run, which is then marked ⚠.
  local start
  start=$(grep -n 'run start ===' "$WATCHDOG_LOG" | tail -n "$n" | head -1 | cut -d: -f1 || true)
  tail -n +"${start:-1}" "$WATCHDOG_LOG" | awk -v G="$GREEN" -v Y="$YELLOW" -v D="$DIM" -v R="$RESET" '
    function add(frag) { checks = checks (checks == "" ? "" : " · ") frag }
    function flush() {
      if (when == "") return
      printf "  %s  %-12s%s\n", (bad ? Y "⚠" : G "✔") R, when, checks
      printf "%s", events
      when = ""; checks = ""; events = ""; bad = 0
    }
    /run start ===/    { flush(); when = substr($1, 6) " " substr($2, 1, 5); next }
    /run complete ===/ { flush(); next }
    /All critical checks passed/ { next }
    {
      if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && $3 ~ /^\[[A-Z]+\]$/) {
        lvl = $3; msg = substr($0, index($0, "] ") + 2)
      } else {
        lvl = ""; msg = $0
      }
      if (msg ~ /^[^:]+: OK( |$)/)   { add(substr(msg, 1, index(msg, ": ") - 1)); next }
      if (msg ~ /^[^:]+: FAIL( |$)/) { add(Y msg R); bad = 1; next }
      if (lvl != "" && lvl != "[INFO]") bad = 1
      events = events "      " D (lvl == "" ? "" : lvl " ") msg R "\n"
    }
    END { flush() }
  '
}

# =============================================================================
#  USAGE / HELP
# =============================================================================

cmd_help() {
  echo -e "
${BOLD}rustdesk-status.sh${RESET} — RustDesk diagnostic and helper tool

${BOLD}Usage:${RESET}
  rustdesk-status.sh [command] [options]

${BOLD}Commands:${RESET}
  ${GREEN}(none)${RESET}           Status dashboard: service, processes, direct access, rendezvous
  ${GREEN}check${RESET}            Full diagnostic with pass/warn/fail output
  ${GREEN}server${RESET}           Test rendezvous server port connectivity
  ${GREEN}logs [N]${RESET}         Show last N journal lines + watchdog log (default: 30)
  ${GREEN}reset${RESET}            Kill stuck --server to reset exponential backoff
                   (refused while a session is live on :${DIRECT_PORT})
  ${GREEN}restart${RESET}          Restart the full RustDesk service (requires sudo)
  ${GREEN}watchdog [N]${RESET}     Timer status + last N watchdog runs, one line each (default: 10)
  ${GREEN}help${RESET}             Show this help

${BOLD}Common flows:${RESET}
  Connect to minty (the normal path, no public server needed):
    RustDesk client → type minty's tailnet IP ($(tailnet_ip)) in the ID box
    rustdesk-status.sh status       # if it fails: is Direct Access green?

  Connect by RustDesk ID, and it shows \"not ready\":
    1. rustdesk-status.sh server    # is the public server up?
    2. rustdesk-status.sh reset     # reset --server backoff if server is up
    3. rustdesk-status.sh status    # confirm connection

  After a system reboot:
    rustdesk-status.sh check        # full diagnostic

${BOLD}See also:${RESET}
  rustdesk-status-guide.md  — architecture, backoff explanation, watchdog integration
"
}

# =============================================================================
#  DISPATCH
# =============================================================================

case "${1:-}" in
  ""       | status)  cmd_status ;;
  check)              cmd_check ;;
  server)             cmd_server ;;
  logs)               cmd_logs "${2:-30}" ;;
  reset)              cmd_reset ;;
  restart)            cmd_restart ;;
  watchdog)           cmd_watchdog "${2:-10}" ;;
  help | --help | -h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command: $1${RESET}" >&2
    cmd_help >&2
    exit 1
    ;;
esac
