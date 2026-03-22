#!/usr/bin/env bash
# =============================================================================
#  Pi5 PodCloud Pre-Installation Readiness Checker
#  Version: 2.2.0
#  Description: Comprehensive validation of OS, hardware, networking,
#               applications, versions, and configurations required for
#               Raspberry Pi 5 PodCloud deployment.
#  Usage: sudo bash pi5_podcloud_precheck.sh
# =============================================================================

# NO set -e  — all errors handled manually so the script never aborts early
set -uo pipefail
# Keep default IFS (space/tab/newline) — custom IFS causes multiline command
# substitutions to embed newlines into scalar variables (the source of "0\n0" bugs)

# ─── ANSI Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
BLUE='\033[0;34m'; WHITE='\033[1;37m'

# ─── Counters — use plain integers, incremented via function (avoids set -e trap)
PASS=0; WARN=0; FAIL=0; SKIP=0
FAILURES=()
WARNINGS=()
UFW_OPENED=0
AUTOFIX_COUNT=0
NEEDS_REBOOT=0
BOOT_CONFIG=""
CMDLINE_FILE=""
SYSCTL_CONF="/etc/sysctl.d/99-podcloud.conf"
LIMITS_CONF="/etc/security/limits.d/99-podcloud.conf"

# ─── Log file ─────────────────────────────────────────────────────────────────
LOG_FILE="/tmp/podcloud_precheck_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
#  HELPER FUNCTIONS
# =============================================================================

# Safe increment — never exits non-zero
inc() { local v="${!1}"; eval "$1=$(( v + 1 ))"; return 0; }

# Right-pad a string to WIDTH with spaces (pure bash, no printf %*s with negative)
pad() {
  local s="$1" w="${2:-60}"
  local len="${#s}" spaces=""
  local pad=$(( w - len ))
  if (( pad > 0 )); then
    printf -v spaces '%*s' "$pad" ''
    printf '%s%s' "$s" "$spaces"
  else
    printf '%s' "$s"
  fi
}

banner() {
  local title="  $1"
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║${WHITE}$(pad "$title" 62)${CYAN}║${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
}

section() {
  local title="  $1"
  echo -e "\n${BOLD}${BLUE}┌─────────────────────────────────────────────┐${RESET}"
  echo -e "${BOLD}${BLUE}│${WHITE}$(pad "$title" 45)${BLUE}│${RESET}"
  echo -e "${BOLD}${BLUE}└─────────────────────────────────────────────┘${RESET}"
}

pass() { echo -e "  ${GREEN}✔${RESET}  $*"; inc PASS; return 0; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; inc WARN; WARNINGS+=("$*"); return 0; }
fail() { echo -e "  ${RED}✘${RESET}  $*"; inc FAIL; FAILURES+=("$*"); return 0; }
info() { echo -e "  ${CYAN}ℹ${RESET}  ${DIM}$*${RESET}"; return 0; }
skip() { echo -e "  ${DIM}○  $* (skipped)${RESET}"; inc SKIP; return 0; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Integer kilobytes → "X.Y GB" string (no bc required)
kb_to_gb() {
  local kb="${1:-0}"
  local gb_int=$(( kb / 1048576 ))
  local rem=$(( (kb % 1048576) * 10 / 1048576 ))
  echo "${gb_int}.${rem}"
}

# version_gte A B → true (0) if A >= B using sort -V
version_gte() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

# =============================================================================
#  HEADER
# =============================================================================
clear
banner "Pi5 PodCloud Pre-Installation Checker v2.2.0"
echo -e "\n${DIM}  Started  : $(date)${RESET}"
echo -e "${DIM}  Hostname : $(hostname)${RESET}"
echo -e "${DIM}  User     : $(id -un) (uid=$(id -u))${RESET}"
echo -e "${DIM}  Log file : $LOG_FILE${RESET}"

# =============================================================================
#  1. PLATFORM & HARDWARE
# =============================================================================
section "1. Platform & Hardware"

# 1.1 Board model
if [[ -f /proc/device-tree/model ]]; then
  BOARD_MODEL=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "unknown")
  info "Detected board: $BOARD_MODEL"
  if echo "$BOARD_MODEL" | grep -qi "Raspberry Pi 5"; then
    pass "Board: Raspberry Pi 5 confirmed"
  elif echo "$BOARD_MODEL" | grep -qi "Raspberry Pi"; then
    warn "Board is Raspberry Pi but NOT Pi 5 ($BOARD_MODEL)"
  else
    fail "Not a Raspberry Pi ($BOARD_MODEL)"
  fi
else
  fail "Cannot read /proc/device-tree/model"
fi

# 1.2 Architecture
ARCH=$(uname -m 2>/dev/null || echo "unknown")
info "Architecture: $ARCH"
if [[ "$ARCH" == "aarch64" ]]; then
  pass "Architecture: aarch64 (64-bit ARM) — required"
else
  fail "Architecture: $ARCH — aarch64 required"
fi

# 1.3 CPU cores
CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)
info "CPU cores: $CPU_CORES"
if (( CPU_CORES >= 4 )); then
  pass "CPU cores: $CPU_CORES (minimum 4 required)"
else
  fail "CPU cores: $CPU_CORES — PodCloud requires ≥4 cores"
fi

# 1.4 RAM
MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
MEM_GB=$(kb_to_gb "$MEM_KB")
info "Total RAM: ${MEM_GB} GB"
if (( MEM_KB >= 7340032 )); then
  pass "RAM: ${MEM_GB} GB — meets 8 GB recommendation"
elif (( MEM_KB >= 3670016 )); then
  warn "RAM: ${MEM_GB} GB — 4 GB minimum met; 8 GB recommended"
else
  fail "RAM: ${MEM_GB} GB — insufficient; PodCloud requires ≥4 GB"
fi

# 1.5 Root free space
ROOT_AVAIL_KB=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
ROOT_TOTAL_KB=$(df -k / 2>/dev/null | awk 'NR==2 {print $2}' || echo 0)
ROOT_AVAIL_GB=$(kb_to_gb "$ROOT_AVAIL_KB")
ROOT_TOTAL_GB=$(kb_to_gb "$ROOT_TOTAL_KB")
info "Root filesystem: ${ROOT_AVAIL_GB} GB free / ${ROOT_TOTAL_GB} GB total"
if (( ROOT_AVAIL_KB >= 20971520 )); then
  pass "Root free space: ${ROOT_AVAIL_GB} GB (≥20 GB required)"
elif (( ROOT_AVAIL_KB >= 10485760 )); then
  warn "Root free space: ${ROOT_AVAIL_GB} GB — 20 GB recommended"
else
  fail "Root free space: ${ROOT_AVAIL_GB} GB — PodCloud requires ≥20 GB free"
fi

# 1.6 /var/lib free space
VAR_AVAIL_KB=$(df -k /var/lib 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
VAR_GB=$(kb_to_gb "$VAR_AVAIL_KB")
info "/var/lib free: ${VAR_GB} GB"
if (( VAR_AVAIL_KB >= 10485760 )); then
  pass "/var/lib free space: ${VAR_GB} GB (≥10 GB for container images)"
else
  warn "/var/lib free space: ${VAR_GB} GB — consider a larger volume"
fi

# 1.7 Storage type
if lsblk -d -o NAME,ROTA 2>/dev/null | grep -q "^nvme"; then
  pass "Storage: NVMe SSD detected — optimal for Pi 5 PodCloud"
else
  ROTA=$(lsblk -d -o ROTA 2>/dev/null | awk 'NR>1 {print $1; exit}' || echo "1")
  if [[ "$ROTA" == "0" ]]; then
    pass "Storage: SSD/flash detected (ROTA=0)"
  else
    warn "Storage: rotational or unknown — NVMe SSD strongly recommended"
  fi
fi

# 1.8 CPU temperature
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
  TEMP_MILLI=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
  TEMP_INT=$(( TEMP_MILLI / 1000 ))
  TEMP_DEC=$(( (TEMP_MILLI % 1000) / 100 ))
  info "CPU temperature: ${TEMP_INT}.${TEMP_DEC}°C"
  if (( TEMP_INT <= 70 )); then
    pass "CPU temperature: ${TEMP_INT}.${TEMP_DEC}°C (safe ≤70°C)"
  elif (( TEMP_INT <= 80 )); then
    warn "CPU temperature: ${TEMP_INT}.${TEMP_DEC}°C — elevated; ensure active cooling"
  else
    fail "CPU temperature: ${TEMP_INT}.${TEMP_DEC}°C — CRITICAL; thermal throttling likely"
  fi
fi

# =============================================================================
#  2. OPERATING SYSTEM
# =============================================================================
section "2. Operating System"

if [[ -f /etc/os-release ]]; then
  OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "")
  OS_ID_LIKE=$(grep '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "")
  OS_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "")
  OS_PRETTY=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
  info "OS: $OS_PRETTY"
  if [[ "$OS_ID" == "debian" ]] || echo "${OS_ID_LIKE}" | grep -qi "debian"; then
    pass "OS family: Debian-based — supported"
  else
    warn "OS: $OS_PRETTY — Debian-based OS recommended"
  fi
  if [[ "$OS_CODENAME" == "bookworm" ]]; then
    pass "OS codename: bookworm (Debian 12) — recommended"
  elif [[ "$OS_CODENAME" == "bullseye" ]]; then
    warn "OS codename: bullseye (Debian 11) — supported but bookworm preferred"
  else
    warn "OS codename: ${OS_CODENAME:-unknown} — verify compatibility"
  fi
else
  fail "Cannot read /etc/os-release"
fi

# 2.2 Kernel version
KERNEL=$(uname -r 2>/dev/null || echo "0.0.0")
info "Kernel: $KERNEL"
KERNEL_BASE=$(echo "$KERNEL" | grep -oP '^\d+\.\d+' || echo "0.0")
if version_gte "$KERNEL_BASE" "6.1"; then
  pass "Kernel: $KERNEL (≥6.1 required for Pi 5)"
elif version_gte "$KERNEL_BASE" "5.15"; then
  warn "Kernel: $KERNEL — 6.1+ recommended for Pi 5"
else
  fail "Kernel: $KERNEL — too old; Pi 5 requires 6.1+"
fi

# 2.3 Hostname resolution
HOSTNAME_VAL=$(hostname 2>/dev/null || echo "localhost")
if getent hosts "$HOSTNAME_VAL" >/dev/null 2>&1; then
  pass "Hostname '$HOSTNAME_VAL' resolves locally"
else
  warn "Hostname '$HOSTNAME_VAL' not in /etc/hosts — add for local service discovery"
fi

# 2.4 Timezone
TZ_SET=$(timedatectl show --property=Timezone --value 2>/dev/null \
         || cat /etc/timezone 2>/dev/null \
         || echo "unknown")
info "Timezone: ${TZ_SET:-unknown}"
if [[ -n "$TZ_SET" && "$TZ_SET" != "unknown" ]]; then
  pass "Timezone configured: $TZ_SET"
else
  warn "Timezone not set — run: sudo timedatectl set-timezone <Region/City>"
fi

# 2.5 NTP sync
NTP_SYNC=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "no")
if [[ "$NTP_SYNC" == "yes" ]]; then
  pass "NTP synchronisation: active"
else
  warn "NTP sync not confirmed — enable with: sudo timedatectl set-ntp true"
fi

# 2.6 Locale
LOCALE_VAL=$(locale 2>/dev/null | grep '^LANG=' | cut -d= -f2 || echo "")
info "Locale LANG: ${LOCALE_VAL:-not set}"
if echo "$LOCALE_VAL" | grep -qi "UTF-8\|utf8"; then
  pass "Locale: UTF-8 encoding confirmed"
else
  warn "Locale '${LOCALE_VAL:-unset}' may not be UTF-8 — run: sudo locale-gen en_US.UTF-8"
fi

# 2.7 Swap
SWAP_KB=$(grep SwapTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
SWAP_MB=$(( SWAP_KB / 1024 ))
info "Swap: ${SWAP_MB} MB"
if (( SWAP_KB >= 1048576 )); then
  pass "Swap: ${SWAP_MB} MB configured"
else
  warn "Swap: ${SWAP_MB} MB — consider ≥1 GB for container workloads"
fi

# 2.8 Root filesystem type
ROOT_FS=$(df -T / 2>/dev/null | awk 'NR==2 {print $2}' || echo "unknown")
info "Root filesystem type: $ROOT_FS"
if echo "$ROOT_FS" | grep -qE "ext4|btrfs|xfs"; then
  pass "Root filesystem: $ROOT_FS — supported"
else
  warn "Root filesystem: $ROOT_FS — ext4/btrfs/xfs recommended"
fi

# 2.9 cgroups v2
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  pass "cgroups v2: enabled"
elif [[ -d /sys/fs/cgroup/memory ]]; then
  warn "cgroups v1 detected — add 'systemd.unified_cgroup_hierarchy=1' to cmdline.txt"
else
  fail "Cannot determine cgroup version"
fi

# 2.10 Kernel modules
for MOD in overlay br_netfilter ip_vs ip_vs_rr ip_vs_wrr nf_conntrack; do
  if lsmod 2>/dev/null | grep -q "^${MOD}"; then
    pass "Kernel module loaded: $MOD"
  elif modprobe --dry-run "$MOD" >/dev/null 2>&1; then
    pass "Kernel module available: $MOD (loadable)"
  else
    warn "Kernel module not found: $MOD — may be needed by container networking"
  fi
done

# 2.11 IPv4 forwarding
IP_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
if [[ "$IP_FORWARD" == "1" ]]; then
  pass "IPv4 forwarding: enabled"
else
  fail "IPv4 forwarding disabled — run: echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-podcloud.conf && sudo sysctl --system"
fi

# =============================================================================
#  3. USERS & PERMISSIONS
# =============================================================================
section "3. Users & Permissions"

CURRENT_USER=$(id -un 2>/dev/null || echo "unknown")
CURRENT_UID=$(id -u 2>/dev/null || echo 9999)

if (( CURRENT_UID == 0 )); then
  pass "Running as root — full access"
elif sudo -n true >/dev/null 2>&1; then
  pass "User '$CURRENT_USER' has passwordless sudo"
elif groups 2>/dev/null | grep -qw sudo; then
  warn "User '$CURRENT_USER' is in sudo group but may need a password"
else
  fail "User '$CURRENT_USER' has no sudo access — required for installation"
fi

if has_cmd docker; then
  if groups 2>/dev/null | grep -qw docker; then
    pass "User '$CURRENT_USER' is in the docker group"
  else
    warn "User '$CURRENT_USER' not in docker group — run: sudo usermod -aG docker $CURRENT_USER"
  fi
fi

# =============================================================================
#  4. NETWORKING
# =============================================================================
section "4. Networking"

# Default route
DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -1 || echo "")
if [[ -n "$DEFAULT_ROUTE" ]]; then
  pass "Default route: $DEFAULT_ROUTE"
else
  fail "No default route — network connectivity required"
fi

# Active interfaces
info "Active interfaces:"
while IFS= read -r line; do
  info "  $line"
done < <(ip -br addr show 2>/dev/null | grep -v '^lo' || echo "  none")

# DNS resolution
for HOST in google.com github.com registry-1.docker.io ghcr.io; do
  if getent hosts "$HOST" >/dev/null 2>&1 \
     || host "$HOST" >/dev/null 2>&1 \
     || nslookup "$HOST" >/dev/null 2>&1; then
    pass "DNS resolves: $HOST"
  else
    fail "DNS resolution failed: $HOST — check /etc/resolv.conf"
  fi
done

# HTTPS reachability
# Note: registry-1.docker.io root (/) returns 404; /v2/ returns 200 or 401 (auth challenge = reachable)
if has_cmd curl; then
  declare -A URL_CHECK
  URL_CHECK=(
    ["https://github.com"]="23"
    ["https://registry-1.docker.io/v2/"]="234"
    ["https://ghcr.io/v2/"]="234"
    ["https://pypi.org"]="23"
  )
  for URL in "${!URL_CHECK[@]}"; do
    VALID_CODES="${URL_CHECK[$URL]}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 --max-time 15 "$URL" 2>/dev/null || echo "000")
    FIRST_DIGIT="${HTTP_CODE:0:1}"
    if echo "$VALID_CODES" | grep -q "$FIRST_DIGIT"; then
      pass "HTTPS reachable: $URL (HTTP $HTTP_CODE)"
    else
      fail "HTTPS unreachable: $URL (HTTP $HTTP_CODE) — check firewall/proxy"
    fi
  done
elif has_cmd wget; then
  for URL in "https://github.com" "https://registry-1.docker.io/v2/"; do
    if wget -q --spider --timeout=15 "$URL" >/dev/null 2>&1; then
      pass "HTTPS reachable: $URL"
    else
      fail "HTTPS unreachable: $URL"
    fi
  done
else
  skip "curl/wget not available — cannot test HTTPS connectivity"
fi

# Required ports
info "Checking required ports are not already bound..."
declare -A PORT_MAP
PORT_MAP=(
  [80]="HTTP ingress"
  [443]="HTTPS ingress"
  [2376]="Docker TLS daemon"
  [2377]="Docker Swarm manager"
  [4789]="Overlay VXLAN"
  [6443]="Kubernetes API server"
  [7946]="Docker Swarm gossip"
  [8080]="PodCloud dashboard/API"
  [10250]="Kubelet API"
  [10257]="kube-controller-manager"
  [10259]="kube-scheduler"
)

if has_cmd ss; then
  SS_OUT=$(ss -tlnp 2>/dev/null || echo "")
  for PORT in "${!PORT_MAP[@]}"; do
    if echo "$SS_OUT" | grep -qE ":${PORT}[[:space:]]|:${PORT}$"; then
      if [[ "$PORT" == "80" || "$PORT" == "443" ]]; then
        info "Port ${PORT} (${PORT_MAP[$PORT]}) in use — PodCloud will take over ingress on this port"
      else
        warn "Port ${PORT} (${PORT_MAP[$PORT]}) already in use — may conflict with PodCloud"
      fi
    else
      pass "Port ${PORT} (${PORT_MAP[$PORT]}) is free"
    fi
  done
elif has_cmd netstat; then
  NS_OUT=$(netstat -tlnp 2>/dev/null || echo "")
  for PORT in "${!PORT_MAP[@]}"; do
    if echo "$NS_OUT" | grep -qE ":${PORT}[[:space:]]"; then
      if [[ "$PORT" == "80" || "$PORT" == "443" ]]; then
        info "Port ${PORT} (${PORT_MAP[$PORT]}) in use — PodCloud will take over ingress on this port"
      else
        warn "Port ${PORT} (${PORT_MAP[$PORT]}) already in use — may conflict"
      fi
    else
      pass "Port ${PORT} (${PORT_MAP[$PORT]}) is free"
    fi
  done
else
  skip "ss/netstat not available — cannot check port conflicts"
fi

# ─── Firewall ─────────────────────────────────────────────────────────────────
# Required PodCloud ports: proto:port:description
declare -a PODCLOUD_PORTS=(
  "tcp:22:SSH management"
  "tcp:80:HTTP ingress"
  "tcp:443:HTTPS ingress"
  "tcp:2376:Docker TLS"
  "tcp:2377:Docker Swarm manager"
  "udp:4789:Overlay VXLAN"
  "tcp:6443:Kubernetes API"
  "tcp:7946:Swarm gossip TCP"
  "udp:7946:Swarm gossip UDP"
  "tcp:8080:PodCloud dashboard"
  "tcp:10250:Kubelet API"
  "tcp:10257:kube-controller-manager"
  "tcp:10259:kube-scheduler"
)

if has_cmd ufw; then
  UFW_STATUS_RAW=$(sudo ufw status verbose 2>/dev/null || true)
  UFW_STATUS_LINE=$(printf "%s" "$UFW_STATUS_RAW" | head -1 | tr -d '[:space:]')
  info "UFW status: $UFW_STATUS_LINE"

  if echo "$UFW_STATUS_LINE" | grep -qi "inactive"; then
    pass "UFW: inactive — all ports accessible"
  else
    info "UFW is active — checking and auto-opening required PodCloud ports..."
    CAN_SUDO=0
    { [[ "$CURRENT_UID" -eq 0 ]] || sudo -n true >/dev/null 2>&1; } && CAN_SUDO=1

    UFW_OPENED_COUNT=0
    UFW_FAILED=()

    for ENTRY in "${PODCLOUD_PORTS[@]}"; do
      PROTO="${ENTRY%%:*}";  REST="${ENTRY#*:}"
      PORT="${REST%%:*}";    DESC="${REST#*:}"

      # ufw status verbose shows rules like "2377/tcp  ALLOW IN  Anywhere"
      # Also check for IPv6 variant and ANY/Anywhere rules
      PORT_ALLOWED=0
      if printf "%s" "$UFW_STATUS_RAW" | grep -qE \
           "^[[:space:]]*${PORT}/(${PROTO})[[:space:]].*ALLOW|^[[:space:]]*${PORT}[[:space:]].*ALLOW"; then
        PORT_ALLOWED=1
      fi

      if (( PORT_ALLOWED == 1 )); then
        pass "UFW: ${PORT}/${PROTO} (${DESC}) — already allowed"
      else
        # Try to open it now rather than just warning
        if (( CAN_SUDO == 1 )); then
          if sudo ufw allow "${PORT}/${PROTO}" >/dev/null 2>&1; then
            pass "UFW: ${PORT}/${PROTO} (${DESC}) — opened ✓"
            inc UFW_OPENED_COUNT
          else
            UFW_FAILED+=("${PORT}/${PROTO} (${DESC})")
            warn "UFW: ${PORT}/${PROTO} (${DESC}) — failed to open; run: sudo ufw allow ${PORT}/${PROTO}"
          fi
        else
          UFW_FAILED+=("${PORT}/${PROTO} (${DESC})")
          warn "UFW: ${PORT}/${PROTO} (${DESC}) — not allowed; run: sudo ufw allow ${PORT}/${PROTO}"
        fi
      fi
    done

    if (( UFW_OPENED_COUNT > 0 )); then
      sudo ufw reload >/dev/null 2>&1 || true
      pass "UFW: $UFW_OPENED_COUNT port(s) opened and firewall reloaded"
    fi

    if (( ${#UFW_FAILED[@]} == 0 )); then
      pass "UFW: all required PodCloud ports confirmed open"
    fi
  fi

elif has_cmd firewall-cmd; then
  warn "firewalld detected — ensure PodCloud ports are open"
  info "  Fix: for p in 22/tcp 80/tcp 443/tcp 2376/tcp 2377/tcp 4789/udp 6443/tcp 7946/tcp 7946/udp 8080/tcp 10250/tcp; do sudo firewall-cmd --permanent --add-port=\$p; done && sudo firewall-cmd --reload"
else
  IPTR_RAW=$(sudo iptables -L INPUT -n 2>/dev/null | grep -cE "DROP|REJECT" || echo 0)
  IPTR=$(echo "$IPTR_RAW" | tr -d '[:space:]'); IPTR="${IPTR:-0}"
  if (( IPTR > 0 )); then
    warn "iptables: $IPTR DROP/REJECT INPUT rules — verify PodCloud ports are allowed"
  else
    pass "iptables: no blocking INPUT rules"
  fi
fi

# MTU
MTU=$(ip link show 2>/dev/null | grep -A1 "state UP" | grep -oP 'mtu \K\d+' | head -1 || echo 0)
info "Interface MTU: ${MTU:-unknown}"
if (( MTU >= 1500 )); then
  pass "MTU: $MTU (≥1500)"
elif (( MTU > 0 )); then
  warn "MTU: $MTU — may cause overlay fragmentation; 1500 recommended"
fi

# =============================================================================
#  5. DOCKER & CONTAINER RUNTIME
# =============================================================================
section "5. Docker & Container Runtime"

if has_cmd docker; then
  DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null \
               || docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 \
               || echo "0.0.0")
  info "Docker version: $DOCKER_VER"
  if version_gte "$DOCKER_VER" "24.0.0"; then
    pass "Docker: $DOCKER_VER (≥24.0)"
  elif version_gte "$DOCKER_VER" "20.10.0"; then
    warn "Docker: $DOCKER_VER — 24.0+ recommended"
  else
    fail "Docker: $DOCKER_VER — too old; minimum 20.10"
  fi

  if docker info >/dev/null 2>&1; then
    pass "Docker daemon: running"

    STORAGE_DRV=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
    info "Storage driver: $STORAGE_DRV"
    if [[ "$STORAGE_DRV" == "overlay2" ]]; then
      pass "Docker storage driver: overlay2 (recommended)"
    else
      warn "Docker storage driver: $STORAGE_DRV — overlay2 recommended"
    fi

    DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
    DOCKER_FREE_KB=$(df -k "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    DOCKER_FREE_GB=$(kb_to_gb "$DOCKER_FREE_KB")
    info "Docker root ($DOCKER_ROOT) free: ${DOCKER_FREE_GB} GB"
    if (( DOCKER_FREE_KB >= 10485760 )); then
      pass "Docker root free: ${DOCKER_FREE_GB} GB (≥10 GB)"
    else
      warn "Docker root free: ${DOCKER_FREE_GB} GB — 10 GB+ recommended"
    fi
  else
    fail "Docker daemon not accessible — run: sudo systemctl start docker"
  fi

  if docker compose version >/dev/null 2>&1; then
    DC_VER=$(docker compose version --short 2>/dev/null || echo "unknown")
    pass "Docker Compose V2: installed ($DC_VER)"
  elif has_cmd docker-compose; then
    DC_VER=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "old")
    warn "docker-compose V1 ($DC_VER) — Compose V2 plugin recommended"
  else
    fail "Docker Compose not found — install: sudo apt install docker-compose-plugin"
  fi

  if systemctl is-enabled --quiet docker 2>/dev/null; then
    pass "Docker service: enabled at boot"
  else
    warn "Docker service not enabled at boot — run: sudo systemctl enable docker"
  fi
else
  fail "Docker not installed — install: curl -fsSL https://get.docker.com | sh"
fi

if has_cmd containerd; then
  CTR_VER=$(containerd --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
  pass "containerd: $CTR_VER"
else
  info "containerd: not standalone (typically bundled with Docker)"
fi

if has_cmd runc; then
  RUNC_VER=$(runc --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
  pass "runc: $RUNC_VER"
else
  info "runc: not standalone (typically bundled with Docker/containerd)"
fi

# =============================================================================
#  6. KUBERNETES / K3S
# =============================================================================
section "6. Kubernetes / K3s"

if has_cmd kubectl; then
  KUBECTL_VER=$(kubectl version --client 2>/dev/null \
                | grep -oP 'v\d+\.\d+\.\d+' | head -1 \
                || echo "unknown")
  pass "kubectl: installed ($KUBECTL_VER)"
  if kubectl cluster-info >/dev/null 2>&1; then
    pass "kubectl: cluster reachable"
  else
    info "kubectl: no cluster yet (expected before install)"
  fi
else
  info "kubectl: not installed (PodCloud installer will provide it)"
fi

if has_cmd k3s; then
  K3S_VER=$(k3s --version 2>/dev/null | head -1 | grep -oP 'v[\d.]+\+k3s\d+' || echo "unknown")
  info "k3s already installed: $K3S_VER"
  if systemctl is-active --quiet k3s 2>/dev/null; then
    warn "k3s service is running — PodCloud may conflict; stop with: sudo systemctl stop k3s"
  else
    info "k3s service not active (ready for fresh install)"
  fi
else
  pass "k3s: not pre-installed (clean environment)"
fi

if has_cmd helm; then
  HELM_VER=$(helm version --short 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "v0.0.0")
  HELM_BARE="${HELM_VER#v}"
  if version_gte "$HELM_BARE" "3.12.0"; then
    pass "Helm: $HELM_VER (≥3.12)"
  else
    warn "Helm: $HELM_VER — upgrade to ≥3.12 recommended"
  fi
else
  info "Helm: not installed (may be required; install: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash)"
fi

# =============================================================================
#  7. REQUIRED SYSTEM PACKAGES
# =============================================================================
section "7. Required System Packages & Tools"

REQUIRED_PKGS=(
  "curl:curl"
  "wget:wget"
  "git:git"
  "jq:jq"
  "openssl:openssl"
  "tar:tar"
  "gzip:gzip"
  "unzip:unzip"
  "make:make"
  "gpg:gnupg"
  "iptables:iptables"
  "ip:iproute2"
  "socat:socat"
  "ethtool:ethtool"
  "rsync:rsync"
  "systemctl:systemd"
)

for PAIR in "${REQUIRED_PKGS[@]}"; do
  CMD="${PAIR%%:*}"
  PKG="${PAIR##*:}"
  if has_cmd "$CMD"; then
    pass "Required: $PKG ($CMD found)"
  else
    fail "Missing: $PKG — install: sudo apt install -y $PKG"
  fi
done

# conntrack: binary may not exist even when kernel module is present on Raspbian
# Accept: binary present OR kernel module loaded OR package installed
if has_cmd conntrack; then
  pass "Required: conntrack (binary found)"
elif lsmod 2>/dev/null | grep -q '^nf_conntrack'; then
  pass "Required: conntrack (kernel module nf_conntrack loaded — binary optional)"
elif dpkg -l conntrack >/dev/null 2>&1; then
  pass "Required: conntrack (package installed)"
else
  fail "Missing: conntrack — install: sudo apt install -y conntrack"
fi
OPTIONAL_PKGS=(
  "htop:htop"
  "ncdu:ncdu"
  "tmux:tmux"
  "lsof:lsof"
  "dig:dnsutils"
  "bc:bc"
  "python3:python3"
  "pip3:python3-pip"
  "nmap:nmap"
  "netstat:net-tools"
)

for PAIR in "${OPTIONAL_PKGS[@]}"; do
  CMD="${PAIR%%:*}"
  PKG="${PAIR##*:}"
  if has_cmd "$CMD"; then
    pass "Optional: $PKG ($CMD found)"
  else
    warn "Optional missing: $PKG — sudo apt install -y $PKG"
  fi
done

# Debugging/diagnostics tools — info only, not warnings
for DBTOOL in tcpdump strace perf; do
  if has_cmd "$DBTOOL"; then
    pass "Debug tool: $DBTOOL present"
  else
    info "Debug tool: $DBTOOL not installed (optional diagnostics — sudo apt install -y $DBTOOL)"
  fi
done

# =============================================================================
#  8. RUNTIME VERSIONS
# =============================================================================
section "8. Runtime Versions"

if has_cmd python3; then
  PY_VER=$(python3 --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
  info "Python3: $PY_VER"
  if version_gte "$PY_VER" "3.10.0"; then
    pass "Python3: $PY_VER (≥3.10 required)"
  elif version_gte "$PY_VER" "3.8.0"; then
    warn "Python3: $PY_VER — 3.10+ recommended"
  else
    fail "Python3: $PY_VER — too old; ≥3.10 required"
  fi
else
  fail "Python3: not installed"
fi

if has_cmd pip3; then
  PIP_VER=$(pip3 --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "unknown")
  pass "pip3: $PIP_VER"
else
  warn "pip3: not installed — sudo apt install python3-pip"
fi

if has_cmd node; then
  NODE_VER=$(node --version 2>/dev/null | tr -d 'v' || echo "0.0.0")
  info "Node.js: v$NODE_VER"
  if version_gte "$NODE_VER" "18.0.0"; then
    pass "Node.js: v$NODE_VER (≥18 LTS)"
  elif version_gte "$NODE_VER" "16.0.0"; then
    warn "Node.js: v$NODE_VER — upgrade to ≥18 LTS"
  else
    fail "Node.js: v$NODE_VER — too old; ≥18 LTS required"
  fi
else
  warn "Node.js: not installed — may be required for PodCloud CLI"
fi

if has_cmd go; then
  GO_VER=$(go version 2>/dev/null | grep -oP 'go\d+\.\d+\.?\d*' | tr -d 'go' | head -1 || echo "0.0.0")
  if version_gte "$GO_VER" "1.21.0"; then
    pass "Go: $GO_VER (≥1.21)"
  else
    info "Go: $GO_VER — 1.21+ recommended (only needed if building PodCloud from source)"
  fi
else
  info "Go: not installed (only needed if building from source)"
fi

if has_cmd openssl; then
  SSL_VER=$(openssl version 2>/dev/null | awk '{print $2}' || echo "unknown")
  info "OpenSSL: $SSL_VER"
  if echo "$SSL_VER" | grep -qP "^3\.|^1\.1\.1"; then
    pass "OpenSSL: $SSL_VER (TLS 1.2/1.3 capable)"
  else
    warn "OpenSSL: $SSL_VER — 1.1.1+ or 3.x recommended"
  fi
fi

# =============================================================================
#  9. SYSTEMD & SERVICES
# =============================================================================
section "9. systemd & Services"

# systemctl is-system-running exits non-zero when state is "degraded" — with
# pipefail enabled, chaining | head | tr || echo in one pipeline causes both
# "degraded" AND "unknown" to land in the variable. Fix: capture raw with || true,
# then process in a second step.
SYS_STATE_RAW=$(systemctl is-system-running 2>/dev/null || true)
SYS_STATE=$(printf "%s" "$SYS_STATE_RAW" | head -1 | tr -d '[:space:]')
SYS_STATE="${SYS_STATE:-unknown}"
info "systemd state: $SYS_STATE"

if [[ "$SYS_STATE" == "running" ]]; then
  pass "systemd: running — all units healthy"
elif [[ "$SYS_STATE" == "degraded" ]]; then
  # Collect failed units — this is a real degraded state, show details
  mapfile -t FAILED_LIST < <(systemctl --failed --no-legend 2>/dev/null | awk 'NF && $1!="UNIT" {print $1}' || true)
  FAILED_COUNT="${#FAILED_LIST[@]}"
  warn "systemd: degraded — $FAILED_COUNT failed unit(s) detected"
  if (( FAILED_COUNT > 0 )); then
    for FUNIT in "${FAILED_LIST[@]}"; do
      # Get a brief description and the last log line
      FDESC=$(systemctl show -p Description --value "$FUNIT" 2>/dev/null || echo "")
      FLOG=$(journalctl -u "$FUNIT" -n 1 --no-pager --output=cat 2>/dev/null | tail -1 || echo "")
      info "  ● $FUNIT${FDESC:+ — $FDESC}"
      [[ -n "$FLOG" ]] && info "    Last log: $FLOG"
      # Offer targeted remediation for common Pi / PodCloud units
      case "$FUNIT" in
        systemd-modules-load.service)
          info "    Fix: sudo systemctl restart systemd-modules-load" ;;
        systemd-timesyncd.service|ntp.service|chrony.service)
          info "    Fix: sudo systemctl restart systemd-timesyncd" ;;
        docker.service)
          info "    Fix: sudo systemctl restart docker" ;;
        ssh.service|sshd.service)
          info "    Fix: sudo systemctl restart ssh" ;;
        NetworkManager.service|networking.service)
          info "    Fix: sudo systemctl restart NetworkManager" ;;
        *)
          info "    Fix: sudo systemctl restart $FUNIT  (or: sudo journalctl -xe -u $FUNIT)" ;;
      esac
    done
  fi
  info "  Note: degraded state will not block PodCloud install unless Docker/network units are failed"
else
  warn "systemd state: $SYS_STATE — check with: systemctl --failed"
fi

for SVC in apache2 nginx haproxy traefik k3s k3s-agent rke2-server rke2-agent microk8s; do
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    warn "Service '$SVC' is running — may conflict with PodCloud"
  fi
done

if has_cmd docker; then
  if systemctl is-active --quiet docker 2>/dev/null; then
    pass "Docker service: active"
  else
    fail "Docker service: not active — run: sudo systemctl start docker"
  fi
fi

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  pass "systemd-resolved: active"
else
  info "systemd-resolved: not active (using /etc/resolv.conf directly)"
fi

# =============================================================================
#  10. TLS / CERTIFICATES
# =============================================================================
section "10. TLS / Certificates"

CA_BUNDLE=""
for CA_PATH in /etc/ssl/certs/ca-certificates.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
  if [[ -f "$CA_PATH" ]]; then
    CA_BUNDLE="$CA_PATH"
    break
  fi
done

if [[ -n "$CA_BUNDLE" ]]; then
  CA_COUNT_RAW=$(grep -c '^-----BEGIN CERTIFICATE' "$CA_BUNDLE" 2>/dev/null || echo 0)
  CA_COUNT=$(echo "$CA_COUNT_RAW" | tr -d '[:space:]')
  CA_COUNT="${CA_COUNT:-0}"
  if (( CA_COUNT > 10 )); then
    pass "CA bundle: $CA_BUNDLE ($CA_COUNT certificates)"
  else
    warn "CA bundle: only $CA_COUNT certs — run: sudo update-ca-certificates"
  fi
else
  fail "CA certificate bundle not found — run: sudo apt install ca-certificates && sudo update-ca-certificates"
fi

if has_cmd curl; then
  # registry-1.docker.io /v2/ returns 401 (auth challenge) = TLS works correctly
  declare -A TLS_CHECK
  TLS_CHECK=(["github.com"]="https://github.com"
             ["registry-1.docker.io"]="https://registry-1.docker.io/v2/")
  for TLS_HOST in "${!TLS_CHECK[@]}"; do
    TLS_URL="${TLS_CHECK[$TLS_HOST]}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 "$TLS_URL" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" != "000" ]]; then
      pass "TLS handshake OK: $TLS_HOST (HTTP $HTTP_CODE)"
    else
      fail "TLS handshake failed: $TLS_HOST — check CA certs and system clock"
    fi
  done
fi

# =============================================================================
#  11. STORAGE & VOLUME CONFIGURATION
# =============================================================================
section "11. Storage & Volume Configuration"

INOTIFY_W=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
INOTIFY_I=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
info "inotify max_user_watches: $INOTIFY_W"
info "inotify max_user_instances: $INOTIFY_I"
if (( INOTIFY_W >= 524288 )); then
  pass "inotify max_user_watches: $INOTIFY_W (≥524288)"
else
  warn "inotify max_user_watches: $INOTIFY_W — will be fixed in auto-tune step (Section 15)"
fi
if (( INOTIFY_I >= 512 )); then
  pass "inotify max_user_instances: $INOTIFY_I (≥512)"
else
  warn "inotify max_user_instances: $INOTIFY_I — will be fixed in auto-tune step (Section 15)"
fi

ULIMIT_N=$(ulimit -n 2>/dev/null || echo 0)
info "File descriptor limit: $ULIMIT_N"
if (( ULIMIT_N >= 65536 )); then
  pass "File descriptor limit: $ULIMIT_N (≥65536)"
else
  warn "File descriptor limit: $ULIMIT_N — will be fixed in auto-tune step (Section 15)"
fi

for DIR in /var/lib/rancher /var/lib/kubelet /var/lib/docker /etc/rancher /opt/cni; do
  if [[ -d "$DIR" ]]; then
    DIR_PCT=$(df -k "$DIR" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}' || echo 0)
    if (( DIR_PCT < 85 )); then
      pass "Directory $DIR: exists (${DIR_PCT}% used)"
    else
      warn "Directory $DIR: ${DIR_PCT}% used — free space recommended"
    fi
  else
    info "Directory $DIR: not yet created (will be made during install)"
  fi
done

# =============================================================================
#  12. SECURITY CONFIGURATION
# =============================================================================
section "12. Security Configuration"

if has_cmd getenforce; then
  SELINUX=$(getenforce 2>/dev/null || echo "unknown")
  if [[ "$SELINUX" == "Enforcing" ]]; then
    warn "SELinux: Enforcing — may block containers; configure policies or set Permissive"
  elif [[ "$SELINUX" == "Permissive" ]]; then
    info "SELinux: Permissive"
  else
    info "SELinux: $SELINUX"
  fi
else
  info "SELinux: not present (Debian default)"
fi

if has_cmd apparmor_status; then
  AA_LOADED=$(sudo apparmor_status 2>/dev/null | grep 'profiles are loaded' | grep -oP '\d+' | head -1 || echo "0")
  info "AppArmor: $AA_LOADED profiles loaded"
fi

UNDERVOLT_RAW=$(dmesg 2>/dev/null | grep -iE "under.voltage|under-voltage" | wc -l || echo 0)
UNDERVOLT=$(echo "$UNDERVOLT_RAW" | tr -d '[:space:]')
UNDERVOLT="${UNDERVOLT:-0}"
if (( UNDERVOLT == 0 )); then
  pass "Power: no under-voltage events in dmesg"
else
  fail "Power: under-voltage detected ($UNDERVOLT events) — use official 27W USB-C PD power supply for Pi 5"
fi

if [[ -f /etc/ssh/sshd_config ]]; then
  if grep -q '^PermitRootLogin no' /etc/ssh/sshd_config 2>/dev/null; then
    pass "SSH: root login disabled"
  else
    info "SSH: root login not explicitly disabled"
  fi
fi

# =============================================================================
#  13. RASPBERRY PI SPECIFIC
# =============================================================================
section "13. Raspberry Pi Specific Configuration"

BOOT_CONFIG=""
for CFG in /boot/firmware/config.txt /boot/config.txt; do
  if [[ -f "$CFG" ]]; then
    BOOT_CONFIG="$CFG"
    break
  fi
done

if [[ -n "$BOOT_CONFIG" ]]; then
  pass "Boot config found: $BOOT_CONFIG"

  GPU_MEM=$(grep -i '^gpu_mem=' "$BOOT_CONFIG" 2>/dev/null | cut -d= -f2 || echo "")
  if [[ -z "$GPU_MEM" ]]; then
    info "gpu_mem not set — will be auto-set to 16 MB in Section 15 auto-tune"
  elif (( GPU_MEM <= 32 )); then
    pass "GPU memory: ${GPU_MEM} MB (minimal — optimal for headless)"
  else
    info "GPU memory: ${GPU_MEM} MB — will be reduced to 16 MB in Section 15 auto-tune"
  fi

  if grep -qi 'dtparam=pciex1_gen=3' "$BOOT_CONFIG" 2>/dev/null; then
    pass "PCIe Gen 3: enabled in $BOOT_CONFIG (optimal NVMe speed)"
  else
    info "PCIe Gen 3 not forced — will be enabled in Section 15 auto-tune"
  fi
else
  warn "Boot config not found (/boot/firmware/config.txt or /boot/config.txt)"
fi

CMDLINE_FILE=""
for CLF in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  if [[ -f "$CLF" ]]; then
    CMDLINE_FILE="$CLF"
    break
  fi
done

if [[ -n "$CMDLINE_FILE" ]]; then
  CMDLINE=$(cat "$CMDLINE_FILE" 2>/dev/null || echo "")
  info "cmdline.txt: $CMDLINE"

  if echo "$CMDLINE" | grep -q 'cgroup_enable=memory'; then
    pass "cgroup_enable=memory: present in cmdline"
  else
    fail "cgroup memory NOT in $CMDLINE_FILE — will be auto-patched in Section 15 auto-tune (requires reboot)"
  fi
  if echo "$CMDLINE" | grep -q 'cgroup_enable=cpuset'; then
    pass "cgroup_enable=cpuset: present in cmdline"
  else
    info "cgroup_enable=cpuset not in cmdline — will be auto-added in Section 15 auto-tune"
  fi
  if echo "$CMDLINE" | grep -q 'swapaccount=1'; then
    pass "swapaccount=1: present in cmdline"
  else
    info "swapaccount=1 not in cmdline — will be auto-added in Section 15 auto-tune"
  fi
else
  warn "cmdline.txt not found — cannot verify cgroup kernel parameters"
fi

if has_cmd vcgencmd; then
  THROTTLE_RAW=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' || echo "0x0")
  THROTTLE_INT=$(( 16#${THROTTLE_RAW#0x} ))
  if (( THROTTLE_INT == 0 )); then
    pass "Throttling: none detected (vcgencmd: $THROTTLE_RAW)"
  else
    fail "Throttling detected (vcgencmd: $THROTTLE_RAW) — check power supply and cooling"
    info "  0x1=under-voltage  0x2=freq-capped  0x4=throttled  0x8=temp-limit"
  fi
  FW_VER=$(vcgencmd version 2>/dev/null | head -1 || echo "unknown")
  info "Pi firmware: $FW_VER"
else
  warn "vcgencmd not found — install: sudo apt install libraspberrypi-bin"
fi

# =============================================================================
#  14. PACKAGE MANAGER & UPDATES
# =============================================================================
section "14. Package Manager & System Updates"

if [[ -f /var/cache/apt/pkgcache.bin ]]; then
  NOW_EPOCH=$(date +%s | tr -d '[:space:]')
  CACHE_EPOCH=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null | tr -d '[:space:]' || echo 0)
  NOW_EPOCH="${NOW_EPOCH:-0}"; CACHE_EPOCH="${CACHE_EPOCH:-0}"
  APT_AGE=$(( (NOW_EPOCH - CACHE_EPOCH) / 86400 ))
  info "apt cache age: ~${APT_AGE} days"
  if (( APT_AGE <= 1 )); then
    pass "apt cache: up to date"
  elif (( APT_AGE <= 7 )); then
    warn "apt cache: ${APT_AGE} days old — run: sudo apt update"
  else
    fail "apt cache: ${APT_AGE} days old — run: sudo apt update"
  fi
fi

if has_cmd apt; then
  UPGRADEABLE_RAW=$(apt list --upgradeable 2>/dev/null | grep -c '\[upgradeable' || echo 0)
  UPGRADEABLE=$(echo "$UPGRADEABLE_RAW" | tr -d '[:space:]')
  UPGRADEABLE="${UPGRADEABLE:-0}"
  if (( UPGRADEABLE == 0 )); then
    pass "System packages: all up to date"
  else
    warn "$UPGRADEABLE package(s) pending update — run: sudo apt upgrade"
  fi
fi

# =============================================================================
#  15. AUTO-TUNE: Apply all kernel, sysctl, Pi config fixes automatically
# =============================================================================
section "15. Auto-Tune & Fixes"

# ── 15a. sysctl parameters ────────────────────────────────────────────────────
info "Checking and applying sysctl tuning parameters..."

declare -A SYSCTL_REC
SYSCTL_REC=(
  ["net.core.somaxconn"]="65535"
  ["net.ipv4.tcp_tw_reuse"]="1"
  ["vm.swappiness"]="10"
  ["vm.overcommit_memory"]="1"
  ["kernel.panic"]="10"
  ["kernel.panic_on_oops"]="1"
  ["net.ipv4.conf.all.forwarding"]="1"
  ["net.bridge.bridge-nf-call-iptables"]="1"
  ["net.bridge.bridge-nf-call-ip6tables"]="1"
  ["fs.inotify.max_user_watches"]="524288"
  ["fs.inotify.max_user_instances"]="512"
  ["fs.file-max"]="2097152"
)

SYSCTL_NEEDED=()
for PARAM in "${!SYSCTL_REC[@]}"; do
  EXPECTED="${SYSCTL_REC[$PARAM]}"
  ACTUAL=$(sysctl -n "$PARAM" 2>/dev/null || echo "N/A")
  if [[ "$ACTUAL" == "N/A" ]]; then
    info "sysctl $PARAM: not available on this kernel (skipping)"
  elif [[ "$ACTUAL" == "$EXPECTED" ]]; then
    pass "sysctl $PARAM = $ACTUAL ✓"
  else
    info "sysctl $PARAM = $ACTUAL → needs $EXPECTED"
    SYSCTL_NEEDED+=("$PARAM=$EXPECTED")
  fi
done

if (( ${#SYSCTL_NEEDED[@]} > 0 )); then
  if [[ "$CURRENT_UID" -eq 0 ]] || sudo -n true >/dev/null 2>&1; then
    info "Writing $SYSCTL_CONF ..."
    {
      echo "# PodCloud pre-installation tuning — $(date)"
      echo "# Generated by pi5_podcloud_precheck.sh"
      echo ""
      for KV in "${SYSCTL_NEEDED[@]}"; do
        echo "$KV"
      done
    } | sudo tee "$SYSCTL_CONF" >/dev/null 2>&1

    if sudo sysctl --system >/dev/null 2>&1; then
      pass "sysctl: ${#SYSCTL_NEEDED[@]} parameter(s) written to $SYSCTL_CONF and applied live"
      inc AUTOFIX_COUNT
      # Verify each was applied
      for KV in "${SYSCTL_NEEDED[@]}"; do
        PARAM="${KV%%=*}"; EXPECTED="${KV##*=}"
        ACTUAL_NOW=$(sysctl -n "$PARAM" 2>/dev/null || echo "?")
        if [[ "$ACTUAL_NOW" == "$EXPECTED" ]]; then
          pass "  Applied: $PARAM = $ACTUAL_NOW"
        else
          warn "  Could not apply live: $PARAM (still $ACTUAL_NOW) — will take effect on next boot"
        fi
      done
    else
      warn "sysctl --system failed — $SYSCTL_CONF written but parameters not applied live; reboot to activate"
    fi
  else
    warn "No sudo access — cannot write $SYSCTL_CONF; add these manually:"
    for KV in "${SYSCTL_NEEDED[@]}"; do
      info "  echo '$KV' | sudo tee -a $SYSCTL_CONF"
    done
  fi
else
  pass "sysctl: all tuning parameters already at recommended values"
fi

# ── 15b. File descriptor limits ───────────────────────────────────────────────
ULIMIT_N=$(ulimit -n 2>/dev/null || echo 0)
if (( ULIMIT_N < 65536 )); then
  if [[ "$CURRENT_UID" -eq 0 ]] || sudo -n true >/dev/null 2>&1; then
    info "Writing $LIMITS_CONF (file descriptor limits)..."
    {
      echo "# PodCloud file descriptor tuning — $(date)"
      echo "* soft nofile 1048576"
      echo "* hard nofile 1048576"
      echo "root soft nofile 1048576"
      echo "root hard nofile 1048576"
    } | sudo tee "$LIMITS_CONF" >/dev/null 2>&1

    # Also patch systemd DefaultLimitNOFILE
    SYSTEMD_CONF="/etc/systemd/system.conf.d/99-podcloud-limits.conf"
    sudo mkdir -p "$(dirname "$SYSTEMD_CONF")" 2>/dev/null || true
    {
      echo "[Manager]"
      echo "DefaultLimitNOFILE=1048576"
    } | sudo tee "$SYSTEMD_CONF" >/dev/null 2>&1

    pass "File descriptor limits: written to $LIMITS_CONF and $SYSTEMD_CONF (reboot or re-login to activate)"
    inc AUTOFIX_COUNT
    inc NEEDS_REBOOT
  else
    warn "No sudo — cannot set file descriptor limits; add manually: echo '* soft nofile 1048576' | sudo tee $LIMITS_CONF"
  fi
else
  pass "File descriptor limit: $ULIMIT_N (≥65536 — OK)"
fi

# ── 15c. /boot/firmware/config.txt Pi 5 optimisations ────────────────────────
if [[ -n "${BOOT_CONFIG:-}" ]]; then
  CONFIG_CHANGED=0

  # gpu_mem
  GPU_MEM_NOW=$(grep -i '^gpu_mem=' "$BOOT_CONFIG" 2>/dev/null | cut -d= -f2 || echo "")
  if [[ -z "$GPU_MEM_NOW" ]] || (( ${GPU_MEM_NOW:-76} > 32 )); then
    if [[ "$CURRENT_UID" -eq 0 ]] || sudo -n true >/dev/null 2>&1; then
      # Remove any existing gpu_mem line then append
      sudo sed -i '/^gpu_mem=/Id' "$BOOT_CONFIG" 2>/dev/null || true
      echo "gpu_mem=16" | sudo tee -a "$BOOT_CONFIG" >/dev/null 2>&1
      pass "config.txt: gpu_mem=16 written to $BOOT_CONFIG"
      inc AUTOFIX_COUNT; inc NEEDS_REBOOT; CONFIG_CHANGED=1
    else
      warn "No sudo — cannot set gpu_mem; add manually: echo 'gpu_mem=16' | sudo tee -a $BOOT_CONFIG"
    fi
  fi

  # PCIe Gen 3
  if ! grep -qi 'dtparam=pciex1_gen=3' "$BOOT_CONFIG" 2>/dev/null; then
    if [[ "$CURRENT_UID" -eq 0 ]] || sudo -n true >/dev/null 2>&1; then
      echo "dtparam=pciex1_gen=3" | sudo tee -a "$BOOT_CONFIG" >/dev/null 2>&1
      pass "config.txt: dtparam=pciex1_gen=3 written to $BOOT_CONFIG (NVMe Gen3 speed)"
      inc AUTOFIX_COUNT; inc NEEDS_REBOOT; CONFIG_CHANGED=1
    else
      info "No sudo — cannot set PCIe Gen 3; add manually: echo 'dtparam=pciex1_gen=3' | sudo tee -a $BOOT_CONFIG"
    fi
  fi

  (( CONFIG_CHANGED == 0 )) && pass "config.txt: all Pi 5 optimisations already present"
fi

# ── 15d. cmdline.txt kernel boot parameters ───────────────────────────────────
if [[ -n "${CMDLINE_FILE:-}" ]]; then
  CMDLINE_NOW=$(cat "$CMDLINE_FILE" 2>/dev/null || echo "")
  CMDLINE_UPDATED="$CMDLINE_NOW"
  CMDLINE_CHANGED=0

  for KPARAM in "cgroup_enable=memory" "cgroup_memory=1" "cgroup_enable=cpuset" "swapaccount=1"; do
    if ! echo "$CMDLINE_UPDATED" | grep -q "$KPARAM"; then
      CMDLINE_UPDATED="$CMDLINE_UPDATED $KPARAM"
      inc CMDLINE_CHANGED
    fi
  done

  if (( CMDLINE_CHANGED > 0 )); then
    if [[ "$CURRENT_UID" -eq 0 ]] || sudo -n true >/dev/null 2>&1; then
      # Backup original
      sudo cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      # Write on single line (cmdline.txt must be one line)
      echo "$CMDLINE_UPDATED" | tr -s ' ' | sudo tee "$CMDLINE_FILE" >/dev/null 2>&1
      pass "cmdline.txt: $CMDLINE_CHANGED parameter(s) added to $CMDLINE_FILE (backup saved)"
      info "  Added: cgroup_enable=memory cgroup_memory=1 cgroup_enable=cpuset swapaccount=1"
      inc AUTOFIX_COUNT; inc NEEDS_REBOOT
    else
      fail "cgroup memory NOT in cmdline.txt and no sudo to fix it — add manually:"
      info "  sudo sed -i 's/$/ cgroup_enable=memory cgroup_memory=1 cgroup_enable=cpuset swapaccount=1/' $CMDLINE_FILE"
    fi
  else
    pass "cmdline.txt: all required kernel parameters present"
  fi
fi

# ── 15e. Summary of auto-fixes ────────────────────────────────────────────────
echo ""
if (( AUTOFIX_COUNT > 0 )); then
  if (( NEEDS_REBOOT > 0 )); then
    warn "Auto-tune applied $AUTOFIX_COUNT fix(es). A REBOOT IS REQUIRED before installing PodCloud."
    info "  Run: sudo reboot"
  else
    pass "Auto-tune applied $AUTOFIX_COUNT fix(es) — all active immediately, no reboot needed"
  fi
else
  pass "Auto-tune: no changes needed — system already optimally configured"
fi

# =============================================================================
#  16. OPTIONAL INTEGRATIONS
# =============================================================================
section "16. Optional Integrations"

if has_cmd mount.nfs4 || dpkg -l nfs-common >/dev/null 2>&1; then
  pass "NFS client: available"
else
  info "NFS client not installed — optional: sudo apt install nfs-common"
fi

for BIN in iscsiadm multipathd; do
  if has_cmd "$BIN"; then
    pass "Optional: $BIN present (useful for Longhorn CSI)"
  else
    info "Optional: $BIN not present (only needed for Longhorn block storage)"
  fi
done

if has_cmd docker && docker info >/dev/null 2>&1; then
  CONTAINER_COUNT_RAW=$(docker ps -q 2>/dev/null | wc -l || echo 0)
  CONTAINER_COUNT=$(echo "$CONTAINER_COUNT_RAW" | tr -d '[:space:]')
  CONTAINER_COUNT="${CONTAINER_COUNT:-0}"
  if (( CONTAINER_COUNT > 0 )); then
    info "$CONTAINER_COUNT container(s) currently running:"
    # Build a flat list of host ports in use by containers
    CONTAINER_PORTS_USED=()
    while IFS= read -r cline; do
      info "  $cline"
      # Extract host port numbers from "0.0.0.0:8080->80/tcp" style strings
      while read -r hport; do
        CONTAINER_PORTS_USED+=("$hport")
      done < <(echo "$cline" | grep -oP ':\K\d+(?=->)' || true)
    done < <(docker ps --format "{{.Names}} — ports: {{.Ports}}" 2>/dev/null || true)

    # Cross-reference against PodCloud required ports
    CONFLICTS=()
    for HPORT in "${CONTAINER_PORTS_USED[@]}"; do
      for ENTRY in "${PODCLOUD_PORTS[@]}"; do
        PPORT="${ENTRY#*:}"; PPORT="${PPORT%%:*}"
        if [[ "$HPORT" == "$PPORT" ]]; then
          CONFLICTS+=("container using port $HPORT — conflicts with PodCloud ${ENTRY##*:}")
        fi
      done
    done

    if (( ${#CONFLICTS[@]} > 0 )); then
      for C in "${CONFLICTS[@]}"; do
        warn "Port conflict: $C"
      done
    else
      pass "Docker: $CONTAINER_COUNT container(s) running — no port conflicts with PodCloud ports"
    fi
  else
    pass "Docker: no running containers (clean environment)"
  fi
fi

# =============================================================================
#  FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║${WHITE}              PRE-CHECK SUMMARY REPORT                       ${CYAN}║${RESET}"
echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  ${GREEN}✔ PASSED   : $PASS${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  ${YELLOW}⚠ WARNINGS : $WARN${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  ${RED}✘ FAILURES : $FAIL${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  ${DIM}○ SKIPPED  : $SKIP${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"

if (( ${#FAILURES[@]} > 0 )); then
  echo -e "\n${BOLD}${RED}  Critical Failures — must resolve before installation:${RESET}"
  for F in "${FAILURES[@]}"; do
    echo -e "  ${RED}✘${RESET} $F"
  done
fi

if (( ${#WARNINGS[@]} > 0 )); then
  echo -e "\n${BOLD}${YELLOW}  Warnings — review before installation:${RESET}"
  for W in "${WARNINGS[@]}"; do
    echo -e "  ${YELLOW}⚠${RESET} $W"
  done
fi

echo ""
if (( FAIL == 0 && WARN == 0 )); then
  if (( NEEDS_REBOOT > 0 )); then
    echo -e "  ${BOLD}${YELLOW}🔁  All checks passed & auto-tune applied. REBOOT REQUIRED before installing PodCloud.${RESET}"
    echo -e "  ${BOLD}${WHITE}    Run: sudo reboot${RESET}"
  else
    echo -e "  ${BOLD}${GREEN}🎉  All checks PASSED — system is ready for Pi5 PodCloud!${RESET}"
  fi
elif (( FAIL == 0 )); then
  echo -e "  ${BOLD}${YELLOW}⚠   No critical failures. Review warnings above before proceeding.${RESET}"
  if (( NEEDS_REBOOT > 0 )); then
    echo -e "  ${BOLD}${YELLOW}🔁  Auto-tune applied changes that require a reboot: sudo reboot${RESET}"
  fi
else
  echo -e "  ${BOLD}${RED}✘   $FAIL critical failure(s) found. Resolve before installing PodCloud.${RESET}"
  if (( NEEDS_REBOOT > 0 )); then
    echo -e "  ${BOLD}${YELLOW}🔁  Also: auto-tune changes require a reboot after fixing failures: sudo reboot${RESET}"
  fi
fi

if (( AUTOFIX_COUNT > 0 )); then
  echo -e "\n  ${BOLD}${CYAN}ℹ  Auto-tune summary: $AUTOFIX_COUNT fix(es) applied automatically${RESET}"
  echo -e "  ${DIM}  Files modified:${RESET}"
  [[ -f "$SYSCTL_CONF" ]]  && echo -e "  ${DIM}    $SYSCTL_CONF${RESET}"
  [[ -f "$LIMITS_CONF" ]]  && echo -e "  ${DIM}    $LIMITS_CONF${RESET}"
  [[ -n "${BOOT_CONFIG:-}" ]] && echo -e "  ${DIM}    $BOOT_CONFIG${RESET}"
  [[ -n "${CMDLINE_FILE:-}" ]] && echo -e "  ${DIM}    $CMDLINE_FILE (original backed up)${RESET}"
fi

echo ""
echo -e "${DIM}  Full log: $LOG_FILE${RESET}"
echo ""

if (( FAIL > 0 )); then
  exit 1
else
  exit 0
fi
