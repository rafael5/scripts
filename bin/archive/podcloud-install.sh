#!/usr/bin/env bash
# =============================================================================
#  PodCloud Installation Script
#  Version: 1.0.0
#  Target:  Raspberry Pi 5 · Debian Bookworm · aarch64 · bash 5.x
#
#  Services deployed:
#    - Nextcloud          (self-hosted cloud storage)
#    - Portainer CE       (Docker GUI)
#    - code-server        (VS Code in browser)
#    - Caddy              (reverse proxy, auto-HTTPS via Tailscale)
#
#  Prerequisites (verified by pre-installation check):
#    - Docker + Docker Compose installed and running
#    - Tailscale installed, authenticated, and connected
#    - NVMe drive mounted (auto-detected or configured via DATA_ROOT)
#    - MagicDNS + HTTPS Certificates enabled in Tailscale admin console
#
#  Usage:
#    sudo bash podcloud_install.sh
#
#  To customise data root or Tailscale hostname before running:
#    DATA_ROOT=/mnt/nvme bash podcloud_install.sh
#
#  Changelog:
#    1.0.0  Initial release
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# =============================================================================
#  1. CONSTANTS & CONFIGURATION
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/tmp/podcloud_install_$(date +%Y%m%d_%H%M%S).log"

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Data storage ------------------------------------------------------------
# NVMe mount detection order — override with DATA_ROOT env var before running
NVME_CANDIDATES=(/mnt/nvme /mnt/data /data /srv/podcloud)
DATA_ROOT=""          # resolved below in section 3

# --- Service ports (internal; Caddy proxies these) ---------------------------
readonly PORT_NEXTCLOUD=80      # Nextcloud apache internal port
readonly PORT_PORTAINER=9000
readonly PORT_CODESERVER=8080   # codercom/code-server default port

# --- Nextcloud DB credentials ------------------------------------------------
# These are internal-only credentials for the Postgres container.
# They are written to .env (chmod 600) — never logged.
readonly NC_DB_NAME="nextcloud"
readonly NC_DB_USER="ncuser"
# Password is generated randomly at runtime (see section 4)
NC_DB_PASS=""         # set in section 4

# --- Tailscale ---------------------------------------------------------------
TS_HOSTNAME=""        # resolved in section 3
TS_DOMAIN=""          # resolved in section 3  e.g. myhost.tail1234.ts.net

# --- Tracking ----------------------------------------------------------------
STEP=0
ERRORS=0
WARNINGS=0

# =============================================================================
#  2. HELPER FUNCTIONS
# =============================================================================

# --- inc: safe counter increment (avoids ((VAR++)) exit-code trap) -----------
inc() {
    local _v
    _v="${!1}"
    eval "$1=$(( _v + 1 ))"
    return 0
}

# --- Output helpers ----------------------------------------------------------
log()  { echo -e "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
pass() { log "${GREEN}  ✔ PASS${RESET}  $*"; }
warn() { log "${YELLOW}  ⚠ WARN${RESET}  $*"; inc WARNINGS; }
fail() { log "${RED}  ✖ FAIL${RESET}  $*"; inc ERRORS; }
info() { log "${CYAN}  ℹ INFO${RESET}  $*"; }
step() {
    inc STEP
    echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}${CYAN}  Step ${STEP}: $*${RESET}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

# --- Command availability guard ----------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- version_gte: sort -V based comparison (never lexicographic) -------------
version_gte() { printf '%s\n%s' "$2" "$1" | sort -V -C; }

# --- Abort on fatal condition ------------------------------------------------
die() { fail "$*"; echo -e "\n${RED}${BOLD}Installation aborted.${RESET} See log: ${LOG_FILE}\n"; exit 1; }

# =============================================================================
#  3. PREFLIGHT CHECKS
# =============================================================================

step "Preflight checks"

# --- Must run as root --------------------------------------------------------
[[ "$EUID" -eq 0 ]] || die "This script must be run as root — use: sudo bash $0"
pass "Running as root"

# --- Docker available and daemon running -------------------------------------
has_cmd docker || die "docker not found — run the pre-installation check first"

# Note: 'docker info' exits non-zero when daemon is stopped — capture safely
DOCKER_INFO_RAW=$(docker info 2>&1 || true)
if echo "$DOCKER_INFO_RAW" | grep -q "Cannot connect\|permission denied\|Is the docker daemon running"; then
    die "Docker daemon is not running — run: sudo systemctl start docker"
fi
pass "Docker daemon is running"

# --- Docker Compose v2 -------------------------------------------------------
has_cmd docker || die "docker not found"
COMPOSE_VERSION_RAW=$(docker compose version 2>/dev/null || true)
COMPOSE_VERSION=$(echo "$COMPOSE_VERSION_RAW" | grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
COMPOSE_VERSION="${COMPOSE_VERSION:-0.0.0}"
version_gte "$COMPOSE_VERSION" "2.0.0" || die "Docker Compose v2+ required (found: ${COMPOSE_VERSION}) — run: sudo apt install docker-compose-plugin"
pass "Docker Compose ${COMPOSE_VERSION} detected"

# --- Tailscale running -------------------------------------------------------
has_cmd tailscale || die "tailscale not found — install Tailscale first"

# Note: 'tailscale status' exits non-zero when not connected — capture safely
TS_STATUS_RAW=$(tailscale status 2>&1 || true)
if echo "$TS_STATUS_RAW" | grep -q -i "not logged in\|stopped\|NeedsLogin\|failed"; then
    die "Tailscale is not connected — run: sudo tailscale up"
fi
pass "Tailscale is connected"

# --- Resolve Tailscale hostname and FQDN ------------------------------------
TS_HOSTNAME_RAW=$(tailscale status --json 2>/dev/null || true)
if has_cmd jq; then
    TS_HOSTNAME=$(echo "$TS_HOSTNAME_RAW" | jq -r '.Self.HostName // empty' 2>/dev/null || true)
    TS_DOMAIN=$(echo "$TS_HOSTNAME_RAW" | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)
fi

# Fallback: parse plain-text status
if [[ -z "$TS_HOSTNAME" ]]; then
    TS_HOSTNAME_RAW2=$(tailscale status 2>/dev/null | head -3 || true)
    TS_DOMAIN=$(echo "$TS_HOSTNAME_RAW2" | grep -oP '[a-z0-9-]+\.ts\.net' | head -1 || true)
    TS_HOSTNAME=$(hostname)
fi

[[ -n "$TS_DOMAIN" ]] || die "Could not determine Tailscale FQDN — is MagicDNS enabled in the Tailscale admin console? (https://login.tailscale.com/admin/dns)"
pass "Tailscale FQDN: ${TS_DOMAIN}"

# --- Resolve NVMe data root --------------------------------------------------
if [[ -n "${DATA_ROOT:-}" ]]; then
    # Honour explicit override
    info "DATA_ROOT overridden to: ${DATA_ROOT}"
else
    for CANDIDATE in "${NVME_CANDIDATES[@]}"; do
        if mountpoint -q "$CANDIDATE" 2>/dev/null; then
            DATA_ROOT="$CANDIDATE"
            break
        fi
    done
fi

if [[ -z "$DATA_ROOT" ]]; then
    # Last resort: find any NVMe block device that is mounted
    NVME_DEV_RAW=$(lsblk -rno NAME,MOUNTPOINT 2>/dev/null | grep nvme | grep -v '^$' || true)
    NVME_MOUNT=$(echo "$NVME_DEV_RAW" | awk '{print $2}' | grep '^/' | head -1 || true)
    DATA_ROOT="${NVME_MOUNT:-}"
fi

[[ -n "$DATA_ROOT" ]] || die "No NVMe mount point found. Mount your NVMe drive and re-run, or set: DATA_ROOT=/your/mount/point sudo bash $0"
pass "Data root: ${DATA_ROOT}"

# --- Verify DATA_ROOT is writable --------------------------------------------
if ! touch "${DATA_ROOT}/.podcloud_write_test" 2>/dev/null; then
    die "Data root ${DATA_ROOT} is not writable by root — check mount permissions"
fi
rm -f "${DATA_ROOT}/.podcloud_write_test"
pass "Data root is writable"

# =============================================================================
#  4. GENERATE SECRETS
# =============================================================================

step "Generating credentials"

# Generate passwords using /dev/urandom — no external dependencies
_gen_pass() { tr -dc 'A-Za-z0-9_@#%^' </dev/urandom | head -c 32; }

NC_DB_PASS="$(_gen_pass)"
NC_ADMIN_PASS="$(_gen_pass)"
NC_ADMIN_USER="admin"

# Note: passwords are never logged — only written to .env (chmod 600)
pass "Nextcloud DB password generated (not logged)"
pass "Nextcloud admin password generated (not logged)"

# =============================================================================
#  5. CREATE DIRECTORY STRUCTURE
# =============================================================================

step "Creating directory structure under ${DATA_ROOT}"

readonly PODCLOUD_DIR="${DATA_ROOT}/podcloud"
readonly DIRS=(
    "${PODCLOUD_DIR}/nextcloud/data"
    "${PODCLOUD_DIR}/nextcloud/config"
    "${PODCLOUD_DIR}/nextcloud/db"
    "${PODCLOUD_DIR}/portainer/data"
    "${PODCLOUD_DIR}/codeserver/config"
    "${PODCLOUD_DIR}/codeserver/workspace"
    "${PODCLOUD_DIR}/caddy/data"
    "${PODCLOUD_DIR}/caddy/config"
)

for DIR in "${DIRS[@]}"; do
    if mkdir -p "$DIR" 2>/dev/null; then
        pass "Created: ${DIR}"
    else
        die "Failed to create directory: ${DIR}"
    fi
done

# Set Nextcloud data directory permissions (www-data uid=33)
chown -R 33:33 "${PODCLOUD_DIR}/nextcloud/data" 2>/dev/null || \
    warn "Could not chown nextcloud/data to www-data (uid 33) — Nextcloud may have permission issues"

# Set codeserver directory permissions (codercom/code-server runs as uid 1000)
chown -R 1000:1000 "${PODCLOUD_DIR}/codeserver" 2>/dev/null || \
    warn "Could not chown codeserver dirs to uid 1000 — code-server may have permission issues"

# =============================================================================
#  6. WRITE ENVIRONMENT FILE
# =============================================================================

step "Writing environment file"

ENV_FILE="${PODCLOUD_DIR}/.env"

cat > "$ENV_FILE" <<EOF
# PodCloud environment — generated $(date)
# DO NOT COMMIT THIS FILE

# Tailscale
TS_DOMAIN=${TS_DOMAIN}

# Nextcloud
NC_DB_NAME=${NC_DB_NAME}
NC_DB_USER=${NC_DB_USER}
NC_DB_PASS=${NC_DB_PASS}
NC_ADMIN_USER=${NC_ADMIN_USER}
NC_ADMIN_PASS=${NC_ADMIN_PASS}
NC_TRUSTED_DOMAIN=${TS_DOMAIN}

# Ports
PORT_NEXTCLOUD=${PORT_NEXTCLOUD}
PORT_PORTAINER=${PORT_PORTAINER}
PORT_CODESERVER=${PORT_CODESERVER}

# Data root
PODCLOUD_DIR=${PODCLOUD_DIR}
EOF

chmod 600 "$ENV_FILE"
pass "Environment file written: ${ENV_FILE} (permissions: 600)"

# Also export vars for docker compose interpolation in this shell
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# =============================================================================
#  7. WRITE DOCKER COMPOSE FILE
# =============================================================================

step "Writing Docker Compose configuration"

COMPOSE_FILE="${PODCLOUD_DIR}/docker-compose.yml"

cat > "$COMPOSE_FILE" <<'COMPOSE_EOF'
# =============================================================================
#  PodCloud — docker-compose.yml
#  Services: Nextcloud, PostgreSQL, Portainer, code-server, Caddy
#  All values sourced from .env in the same directory
# =============================================================================

services:

  # ---------------------------------------------------------------------------
  #  PostgreSQL — Nextcloud database
  # ---------------------------------------------------------------------------
  db:
    image: postgres:16-alpine
    container_name: podcloud-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${NC_DB_NAME}
      POSTGRES_USER: ${NC_DB_USER}
      POSTGRES_PASSWORD: ${NC_DB_PASS}
    volumes:
      - ${PODCLOUD_DIR}/nextcloud/db:/var/lib/postgresql/data
    networks:
      - podcloud-internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${NC_DB_USER} -d ${NC_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ---------------------------------------------------------------------------
  #  Nextcloud
  # ---------------------------------------------------------------------------
  nextcloud:
    image: nextcloud:28-apache
    container_name: podcloud-nextcloud
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      POSTGRES_HOST: db
      POSTGRES_DB: ${NC_DB_NAME}
      POSTGRES_USER: ${NC_DB_USER}
      POSTGRES_PASSWORD: ${NC_DB_PASS}
      NEXTCLOUD_ADMIN_USER: ${NC_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NC_ADMIN_PASS}
      NEXTCLOUD_TRUSTED_DOMAINS: ${TS_DOMAIN}
      # Tell Nextcloud it is behind a reverse proxy
      TRUSTED_PROXIES: 172.16.0.0/12
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: ${TS_DOMAIN}
    volumes:
      - ${PODCLOUD_DIR}/nextcloud/data:/var/www/html/data
      - ${PODCLOUD_DIR}/nextcloud/config:/var/www/html/config
    networks:
      - podcloud-internal
    expose:
      - "${PORT_NEXTCLOUD}"

  # ---------------------------------------------------------------------------
  #  Portainer CE — Docker management UI
  # ---------------------------------------------------------------------------
  portainer:
    image: portainer/portainer-ce:latest
    container_name: podcloud-portainer
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${PODCLOUD_DIR}/portainer/data:/data
    networks:
      - podcloud-internal
    expose:
      - "${PORT_PORTAINER}"

  # ---------------------------------------------------------------------------
  #  code-server — VS Code in the browser
  #  Image: codercom/code-server (Docker Hub, Cloudflare CDN — no AWS dependency)
  #  This is the upstream project that other registries repackage.
  #  Default port is 8080. Config lives at /home/coder/.config/code-server/
  #  Password auth disabled — access is restricted to Tailscale network only.
  # ---------------------------------------------------------------------------
  codeserver:
    image: codercom/code-server:latest
    container_name: podcloud-codeserver
    restart: unless-stopped
    user: "1000:1000"
    environment:
      PASSWORD: ""
      DOCKER_USER: "1000"
    command: ["--auth", "none", "--bind-addr", "0.0.0.0:8080", "--proxy-domain", "${TS_DOMAIN}"]
    volumes:
      - ${PODCLOUD_DIR}/codeserver/config:/home/coder/.config
      - ${PODCLOUD_DIR}/codeserver/workspace:/home/coder/workspace
    networks:
      - podcloud-internal
    expose:
      - "8080"

  # ---------------------------------------------------------------------------
  #  Caddy — Reverse proxy with automatic Tailscale HTTPS
  #
  #  Caddy natively fetches *.ts.net certificates from the local Tailscale
  #  daemon at handshake time — no manual cert commands or renewal cron jobs.
  #  Requires: TS_PERMIT_CERT_UID set in /etc/default/tailscaled (done below
  #  in the install script, section 8).
  # ---------------------------------------------------------------------------
  caddy:
    image: caddy:2-alpine
    container_name: podcloud-caddy
    restart: unless-stopped
    # Run as root so Caddy can access the Tailscale socket for certs
    user: root
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${PODCLOUD_DIR}/caddy/config/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${PODCLOUD_DIR}/caddy/data:/data
      - ${PODCLOUD_DIR}/caddy/config:/config
      # Mount Tailscale socket so Caddy can fetch certs from local tailscaled
      - /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock:ro
    networks:
      - podcloud-internal
    depends_on:
      - nextcloud
      - portainer
      - codeserver

networks:
  podcloud-internal:
    driver: bridge
COMPOSE_EOF

pass "Docker Compose file written: ${COMPOSE_FILE}"

# =============================================================================
#  8. WRITE CADDYFILE
# =============================================================================

step "Writing Caddyfile"

CADDYFILE="${PODCLOUD_DIR}/caddy/config/Caddyfile"

# Caddy automatically fetches *.ts.net certs from the local tailscaled socket.
# Sub-paths route to each service — single hostname, no subdomain DNS required.
cat > "$CADDYFILE" <<CADDY_EOF
# =============================================================================
#  PodCloud Caddyfile
#  HTTPS provided automatically for ${TS_DOMAIN} by local Tailscale daemon.
#  No Let's Encrypt, no manual certs, no renewal cron.
# =============================================================================

${TS_DOMAIN} {

    # Nextcloud
    handle /nextcloud* {
        reverse_proxy nextcloud:${PORT_NEXTCLOUD}
    }

    # Portainer
    handle /portainer* {
        uri strip_prefix /portainer
        reverse_proxy portainer:${PORT_PORTAINER}
    }

    # code-server (codercom/code-server, port 8080)
    handle /code* {
        uri strip_prefix /code
        reverse_proxy codeserver:8080
    }

    # Default: redirect root to Nextcloud
    handle {
        redir /nextcloud permanent
    }

    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "no-referrer-when-downgrade"
    }

    # Logging
    log {
        output file /data/caddy_access.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}
CADDY_EOF

pass "Caddyfile written: ${CADDYFILE}"

# =============================================================================
#  9. VERIFY TAILSCALE CERT PERMISSIONS (READ-ONLY GUARD)
# =============================================================================

step "Verifying Tailscale cert permissions for Caddy"

# THIS STEP DOES NOT TOUCH TAILSCALE IN ANY WAY.
# It is a read-only guard that confirms podcloud_ts_permit_check.sh was run
# and passed before this install script was executed.
#
# Restarting tailscaled during an SSH session over a Tailscale address will
# drop the SSH connection — it must never happen in this script.
# All Tailscale configuration is handled exclusively by the pre-check scripts.

readonly _TS_DEFAULTS="/etc/default/tailscaled"

# Check 1: config file contains root
_TS_FILE_RAW=$(grep "^TS_PERMIT_CERT_UID" "$_TS_DEFAULTS" 2>/dev/null || true)
_TS_FILE=$(echo "$_TS_FILE_RAW" | tr -d '[:space:]')
_TS_FILE="${_TS_FILE:-}"

if [[ -z "$_TS_FILE" ]]; then
    die "TS_PERMIT_CERT_UID not found in ${_TS_DEFAULTS}. Run Script 2 first: sudo bash podcloud_ts_permit_check.sh"
fi

if ! echo "$_TS_FILE" | grep -q "root"; then
    die "TS_PERMIT_CERT_UID in ${_TS_DEFAULTS} does not include 'root' (found: ${_TS_FILE}). Run: sudo bash podcloud_ts_permit_check.sh"
fi

pass "Config file check: ${_TS_FILE}"

# Check 2: live tailscaled process has root in its environment
_TS_PID_RAW=$(pgrep -x tailscaled 2>/dev/null || true)
_TS_PID=$(echo "$_TS_PID_RAW" | tr -d '[:space:]')
_TS_PID="${_TS_PID:-}"

if [[ -n "$_TS_PID" ]]; then
    _TS_LIVE_RAW=$(strings "/proc/${_TS_PID}/environ" 2>/dev/null \
        | grep "^TS_PERMIT_CERT_UID" || true)
    _TS_LIVE=$(echo "$_TS_LIVE_RAW" | tr -d '[:space:]')
    _TS_LIVE="${_TS_LIVE:-}"

    if [[ -n "$_TS_LIVE" ]] && echo "$_TS_LIVE" | grep -q "root"; then
        pass "Live process check: ${_TS_LIVE} — Caddy can fetch certs immediately"
    else
        # Config file is correct but live process hasn't reloaded it yet.
        # This is non-fatal: Caddy retries cert fetching automatically, and
        # will succeed after the Pi reboot that follows this install.
        warn "Live tailscaled process has not yet loaded TS_PERMIT_CERT_UID=root"
        warn "Caddy may log one cert error on first start — this resolves after reboot"
        info "Reboot the Pi after install completes: sudo reboot"
    fi
else
    warn "Could not determine tailscaled PID — skipping live environment check"
fi

# =============================================================================
#  10. START SERVICES
# =============================================================================

# =============================================================================
#  10. START SERVICES
# =============================================================================

step "Starting PodCloud services"

cd "$PODCLOUD_DIR" || die "Cannot cd to ${PODCLOUD_DIR}"

# -----------------------------------------------------------------------------
#  10a. Registry reachability pre-check
# -----------------------------------------------------------------------------
# Check each registry before attempting any pull. Fail fast with a clear
# message rather than waiting for Docker's own timeout (which can be 60s+
# per image with no feedback).
#
# Note: Docker Hub /v2/ returns HTTP 401 (auth challenge) when reachable —
# this is correct behaviour, not an error. Any non-000 code = reachable.

info "Checking registry reachability before pulling..."

declare -A REGISTRY_STATUS   # registry hostname → ok|fail
declare -a REGISTRY_FAILURES=()

_check_registry() {
    local name="$1"
    local url="$2"
    local code_raw
    # curl exits non-zero on connection failure — capture safely
    code_raw=$(curl -sk --max-time 8 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    local code
    code=$(echo "$code_raw" | tr -d '[:space:]')
    code="${code:-000}"
    if [[ "$code" != "000" ]]; then
        pass "Registry reachable: ${name} (HTTP ${code})"
        REGISTRY_STATUS["$name"]="ok"
    else
        fail "Registry UNREACHABLE: ${name} — timeout or no route to host"
        REGISTRY_STATUS["$name"]="fail"
        REGISTRY_FAILURES+=("$name")
    fi
}

# Note: Docker Hub /v2/ returns 401 (auth challenge) = reachable + TLS working
_check_registry "registry-1.docker.io" "https://registry-1.docker.io/v2/"
_check_registry "lscr.io"              "https://lscr.io/v2/"

if [[ ${#REGISTRY_FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}  The following registries are unreachable:${RESET}"
    for R in "${REGISTRY_FAILURES[@]}"; do
        echo -e "    ${RED}✖${RESET} ${R}"
    done
    echo ""
    echo -e "  ${BOLD}Images that need each registry:${RESET}"
    echo -e "    registry-1.docker.io : nextcloud, postgres, portainer, caddy, codercom/code-server"
    echo -e "    lscr.io              : (not used in this install)"
    echo ""
    echo -e "  ${BOLD}Suggested fixes:${RESET}"
    echo -e "    1. Wait 2-5 minutes and re-run — Docker Hub has intermittent timeouts"
    echo -e "    2. Check Pi internet connectivity: ping -c 3 8.8.8.8"
    echo -e "    3. Check router/ISP for blocks on registry IPs"
    echo ""
    die "Cannot pull images — registries unreachable. Resolve connectivity and re-run."
fi

# -----------------------------------------------------------------------------
#  10b. Image manifest — show exactly what will be pulled, require confirmation
# -----------------------------------------------------------------------------

echo ""
echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}${CYAN}│  Images to be pulled                                         │${RESET}"
echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────┘${RESET}"
echo ""

# Define the image list explicitly — single source of truth
declare -a IMAGES=(
    "postgres:16-alpine|Docker Hub|Nextcloud database"
    "nextcloud:28-apache|Docker Hub|Nextcloud application"
    "portainer/portainer-ce:latest|Docker Hub|Docker GUI"
    "codercom/code-server:latest|Docker Hub|VS Code in browser"
    "caddy:2-alpine|Docker Hub|Reverse proxy (HTTPS)"
)

# Check which images are already present locally to save time
declare -a TO_PULL=()
declare -a ALREADY_PRESENT=()

for ENTRY in "${IMAGES[@]}"; do
    IMG="${ENTRY%%|*}"
    REST="${ENTRY#*|}"
    REGISTRY="${REST%%|*}"
    DESC="${REST##*|}"

    # docker image inspect exits non-zero if image not local — capture safely
    LOCAL_RAW=$(docker image inspect "$IMG" --format='{{.Id}}' 2>/dev/null || true)
    LOCAL=$(echo "$LOCAL_RAW" | tr -d '[:space:]')
    LOCAL="${LOCAL:-}"

    if [[ -n "$LOCAL" ]]; then
        echo -e "  ${GREEN}✔ Already local${RESET}  ${BOLD}${IMG}${RESET}"
        echo -e "              ${DIM}${DESC} · ${REGISTRY}${RESET}"
        ALREADY_PRESENT+=("$IMG")
    else
        echo -e "  ${YELLOW}↓ Will pull  ${RESET}  ${BOLD}${IMG}${RESET}"
        echo -e "              ${DIM}${DESC} · ${REGISTRY}${RESET}"
        TO_PULL+=("$IMG")
    fi
    echo ""
done

if [[ ${#TO_PULL[@]} -eq 0 ]]; then
    pass "All images already present locally — no pull needed"
else
    echo -e "  ${BOLD}${#TO_PULL[@]} image(s) to download.${RESET} ${#ALREADY_PRESENT[@]} already cached locally."
    echo ""
    echo -e "  ${YELLOW}Note:${RESET} Pulls can take 5-20 minutes on a slow connection."
    echo -e "  ${YELLOW}Note:${RESET} If a pull times out, re-run the script — already-pulled"
    echo -e "         images are cached and will be skipped on the next attempt."
    echo ""

    # --- User confirmation ---------------------------------------------------
    echo -e "${BOLD}  Proceed with pulling ${#TO_PULL[@]} image(s)? [y/N]${RESET} " && read -r _CONFIRM
    _CONFIRM=$(echo "${_CONFIRM:-n}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    if [[ "$_CONFIRM" != "y" && "$_CONFIRM" != "yes" ]]; then
        echo ""
        echo -e "  Pull cancelled. Re-run when ready: ${BOLD}sudo bash podcloud_install.sh${RESET}"
        echo ""
        exit 0
    fi

    # --- Pull with per-image retry -------------------------------------------
    echo ""
    info "Starting image pulls..."

    _MAX_PULL_ATTEMPTS=3

    for IMG in "${TO_PULL[@]}"; do
        _attempt=0
        _pulled=0
        while [[ $_attempt -lt $_MAX_PULL_ATTEMPTS ]]; do
            inc _attempt
            info "Pulling ${IMG} (attempt ${_attempt}/${_MAX_PULL_ATTEMPTS})..."
            # docker pull exits non-zero on failure — capture safely
            if docker pull "$IMG" 2>&1 | tee -a "$LOG_FILE"; then
                pass "Pulled: ${IMG}"
                _pulled=1
                break
            else
                if [[ $_attempt -lt $_MAX_PULL_ATTEMPTS ]]; then
                    warn "Pull failed for ${IMG} — waiting 10s before retry..."
                    sleep 10
                fi
            fi
        done
        if [[ $_pulled -eq 0 ]]; then
            die "Failed to pull ${IMG} after ${_MAX_PULL_ATTEMPTS} attempts. Check connectivity and re-run."
        fi
    done

    pass "All images pulled successfully"
fi

# -----------------------------------------------------------------------------
#  10c. Start services
# -----------------------------------------------------------------------------

echo ""
info "Starting containers..."
if docker compose up -d 2>&1 | tee -a "$LOG_FILE"; then
    pass "docker compose up succeeded"
else
    die "docker compose up failed — check log: ${LOG_FILE}"
fi

# =============================================================================
#  11. HEALTH CHECKS
# =============================================================================

step "Waiting for services to become healthy"

_wait_healthy() {
    local name="$1"
    local max_attempts=30
    local attempt=0
    local status_raw=""
    local status=""

    while [[ $attempt -lt $max_attempts ]]; do
        # Note: docker inspect exits non-zero for missing containers; capture safely
        status_raw=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || true)
        status=$(echo "$status_raw" | tr -d '[:space:]')
        status="${status:-unknown}"

        case "$status" in
            healthy)   pass "${name} is healthy"; return 0 ;;
            unhealthy) fail "${name} reported unhealthy"; return 1 ;;
            # starting / unknown — keep waiting
            *)
                inc attempt
                sleep 5
                ;;
        esac
    done
    warn "${name} did not report healthy within $(( max_attempts * 5 ))s — it may still be initialising"
    return 0  # non-fatal; let user check manually
}

_wait_healthy "podcloud-db"

# For containers without Docker healthchecks, poll the port via Caddy
_wait_http() {
    local label="$1"
    local url="$2"
    local max_attempts=24  # 24 × 5s = 2 minutes
    local attempt=0
    local http_code=""

    while [[ $attempt -lt $max_attempts ]]; do
        # Note: curl exits non-zero on connection refused; capture safely
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        http_code=$(echo "$http_code" | tr -d '[:space:]')
        # Any response (even 302/401/404) means the service is up
        if [[ "$http_code" != "000" ]]; then
            pass "${label} is responding (HTTP ${http_code})"
            return 0
        fi
        inc attempt
        sleep 5
    done
    warn "${label} did not respond within $(( max_attempts * 5 ))s — check: docker logs ${label}"
    return 0
}

_wait_http "podcloud-nextcloud" "http://localhost:${PORT_NEXTCLOUD}/status.php"
_wait_http "podcloud-portainer" "http://localhost:${PORT_PORTAINER}"
_wait_http "podcloud-codeserver" "http://localhost:${PORT_CODESERVER}"

# =============================================================================
#  12. WRITE CREDENTIALS SUMMARY FILE
# =============================================================================

step "Writing credentials summary"

CREDS_FILE="${PODCLOUD_DIR}/CREDENTIALS.txt"

cat > "$CREDS_FILE" <<CREDS_EOF
# =============================================================================
#  PodCloud Credentials — KEEP THIS FILE SECURE
#  Generated: $(date)
#  Permissions: 600 (root only)
# =============================================================================

Tailscale FQDN : https://${TS_DOMAIN}

Service URLs (via Tailscale — only accessible on your tailnet):
  Nextcloud   : https://${TS_DOMAIN}/nextcloud
  Portainer   : https://${TS_DOMAIN}/portainer
  code-server : https://${TS_DOMAIN}/code

Nextcloud admin login:
  Username    : ${NC_ADMIN_USER}
  Password    : ${NC_ADMIN_PASS}

Nextcloud database (internal — not exposed outside Docker network):
  DB name     : ${NC_DB_NAME}
  DB user     : ${NC_DB_USER}
  DB password : ${NC_DB_PASS}

Files:
  Compose dir : ${PODCLOUD_DIR}
  Compose file: ${COMPOSE_FILE}
  Env file    : ${ENV_FILE}
  Caddyfile   : ${CADDYFILE}
  This file   : ${CREDS_FILE}
  Install log : ${LOG_FILE}
CREDS_EOF

chmod 600 "$CREDS_FILE"
pass "Credentials written: ${CREDS_FILE} (permissions: 600)"

# =============================================================================
#  13. FINAL SUMMARY
# =============================================================================

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║              PodCloud Installation Complete                  ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ $ERRORS -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}${ERRORS} error(s) occurred.${RESET} Review the log: ${LOG_FILE}"
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}${WARNINGS} warning(s).${RESET} Review the log: ${LOG_FILE}"
else
    echo -e "  ${GREEN}${BOLD}All steps completed without errors.${RESET}"
fi

echo ""
echo -e "  ${BOLD}Your services are available on your Tailscale network:${RESET}"
echo -e "  ${CYAN}Nextcloud   :${RESET} https://${TS_DOMAIN}/nextcloud"
echo -e "  ${CYAN}Portainer   :${RESET} https://${TS_DOMAIN}/portainer"
echo -e "  ${CYAN}code-server :${RESET} https://${TS_DOMAIN}/code"
echo ""
echo -e "  ${BOLD}Credentials saved to:${RESET} ${CREDS_FILE}"
echo -e "  ${BOLD}Install log saved to:${RESET} ${LOG_FILE}"
echo ""
echo -e "  ${YELLOW}NOTE:${RESET} If this is the first run of Nextcloud, initial setup may"
echo -e "  take 2–5 minutes. Wait before accessing the Nextcloud URL."
echo ""
echo -e "  ${YELLOW}NOTE:${RESET} Ensure MagicDNS and HTTPS Certificates are enabled in"
echo -e "  your Tailscale admin console before accessing HTTPS URLs:"
echo -e "  ${CYAN}https://login.tailscale.com/admin/dns${RESET}"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  View logs  : cd ${PODCLOUD_DIR} && docker compose logs -f"
echo -e "  Stop all   : cd ${PODCLOUD_DIR} && docker compose down"
echo -e "  Restart    : cd ${PODCLOUD_DIR} && docker compose restart"
echo ""
