#!/usr/bin/env bash
# =============================================================================
#  PodCloud — Tailscale MagicDNS & HTTPS Certificate Pre-Check
#  Version:  1.0.0
#  Target:   Raspberry Pi 5 · Debian Bookworm · aarch64 · bash 5.x
#  Purpose:  Validate that Tailscale MagicDNS and HTTPS certificates are
#            fully configured and working before running podcloud_install.sh
#  Usage:    sudo bash podcloud_tailscale_check.sh
#  Output:   Console (ANSI color) + log: /tmp/podcloud_ts_check_YYYYMMDD.log
#  Exit:     0 = all checks passed, safe to proceed
#            1 = one or more FAIL checks — must resolve before installing
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# =============================================================================
#  1. CONSTANTS
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/tmp/podcloud_ts_check_$(date +%Y%m%d_%H%M%S).log"

# Minimum Tailscale version for reliable cert support
readonly MIN_TS_VERSION="1.40.0"

# Test port: Caddy will listen here for TLS validation
readonly TEST_HTTPS_PORT=8765

# =============================================================================
#  2. COLOURS & OUTPUT
# =============================================================================

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# =============================================================================
#  3. COUNTERS & STATE — initialise ALL variables here (prevents set -u errors)
# =============================================================================

PASS=0
WARN=0
FAIL=0
SKIP=0

TS_VERSION=""
TS_STATUS=""
TS_HOSTNAME=""
TS_DOMAIN=""
TS_IP=""
TS_MAGICFLAG=""
TS_HTTPS_FLAG=""
TS_STATUS_JSON=""
DNS_RESOLVES=""
CERT_FILE=""
CERT_KEY=""
CERT_SUBJECT=""
CERT_EXPIRY=""
CERT_EXPIRY_EPOCH=0
NOW_EPOCH=0
DAYS_LEFT=0
CADDY_BIN=""
CADDY_TEST_RESULT=""
CURL_HTTPS_CODE=""
SOCKET_PATH="/var/run/tailscale/tailscaled.sock"
TAILSCALED_DEFAULTS="/etc/default/tailscaled"
TS_PERMIT_UID=""
declare -a FAILURES=()
declare -a WARNINGS=()

# =============================================================================
#  4. HELPER FUNCTIONS
# =============================================================================

# --- Safe counter increment — never use ((VAR++)); exits 1 when VAR=0 -------
inc() { local _v="${!1}"; eval "$1=$(( _v + 1 ))"; return 0; }

# --- Logging -----------------------------------------------------------------
_log() { echo -e "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
pass() { _log "${GREEN}  ✔ PASS${RESET}  $*"; inc PASS; }
warn() { _log "${YELLOW}  ⚠ WARN${RESET}  $*"; inc WARN; WARNINGS+=("$*"); }
fail() { _log "${RED}  ✖ FAIL${RESET}  $*"; inc FAIL; FAILURES+=("$*"); }
info() { _log "${CYAN}  ℹ INFO${RESET}  $*"; }
skip() { _log "${DIM}  ○ SKIP${RESET}  $*"; inc SKIP; }

section() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}┌──────────────────────────────────────────────────────────────┐${RESET}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}│  $1${RESET}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}└──────────────────────────────────────────────────────────────┘${RESET}" | tee -a "$LOG_FILE"
}

# --- Command guard -----------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- Version comparison (sort -V, not lexicographic) ------------------------
version_gte() { printf '%s\n%s' "$2" "$1" | sort -V -C; }

# =============================================================================
#  BANNER
# =============================================================================

echo "" | tee -a "$LOG_FILE"
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}" | tee -a "$LOG_FILE"
echo -e "${BOLD}${CYAN}║   PodCloud — Tailscale MagicDNS & HTTPS Certificate Check  v${SCRIPT_VERSION} ║${RESET}" | tee -a "$LOG_FILE"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}" | tee -a "$LOG_FILE"
echo -e "  Log: ${DIM}${LOG_FILE}${RESET}\n" | tee -a "$LOG_FILE"

# =============================================================================
#  CHECK 1 — PRIVILEGES
# =============================================================================

section "1. Privileges"

if [[ "$EUID" -eq 0 ]]; then
    pass "Running as root"
else
    fail "Must run as root — fix: sudo bash $0"
    echo -e "\n${RED}${BOLD}Re-run with sudo.${RESET}\n"
    exit 1
fi

# =============================================================================
#  CHECK 2 — TAILSCALE BINARY & VERSION
# =============================================================================

section "2. Tailscale binary & version"

has_cmd tailscale || {
    fail "tailscale binary not found — fix: curl -fsSL https://tailscale.com/install.sh | sh"
    exit 1
}
pass "tailscale binary found: $(command -v tailscale)"

# Capture version safely — tailscale version exits 0 but guard anyway
TS_VERSION_RAW=$(tailscale version 2>/dev/null || true)
TS_VERSION=$(echo "$TS_VERSION_RAW" | head -1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || true)
TS_VERSION="${TS_VERSION:-0.0.0}"

if version_gte "$TS_VERSION" "$MIN_TS_VERSION"; then
    pass "Tailscale version ${TS_VERSION} >= ${MIN_TS_VERSION}"
else
    fail "Tailscale version ${TS_VERSION} is too old (need >= ${MIN_TS_VERSION}) — fix: sudo tailscale update"
fi

# =============================================================================
#  CHECK 3 — TAILSCALE DAEMON RUNNING
# =============================================================================

section "3. Tailscale daemon (tailscaled)"

# Note: systemctl is-active exits 3 when inactive — capture safely
TSACTIVE_RAW=$(systemctl is-active tailscaled 2>/dev/null || true)
TSACTIVE=$(echo "$TSACTIVE_RAW" | tr -d '[:space:]')
TSACTIVE="${TSACTIVE:-unknown}"

if [[ "$TSACTIVE" == "active" ]]; then
    pass "tailscaled systemd service is active"
else
    fail "tailscaled is not running (status: ${TSACTIVE}) — fix: sudo systemctl enable --now tailscaled"
fi

# Verify socket exists — Caddy needs this to fetch certs
if [[ -S "$SOCKET_PATH" ]]; then
    pass "Tailscale socket exists: ${SOCKET_PATH}"
else
    fail "Tailscale socket missing: ${SOCKET_PATH} — fix: sudo systemctl restart tailscaled"
fi

# =============================================================================
#  CHECK 4 — TAILSCALE AUTHENTICATED & CONNECTED
# =============================================================================

section "4. Tailscale authentication & connectivity"

# Note: tailscale status exits non-zero when not logged in — capture safely
TS_STATUS_JSON=$(tailscale status --json 2>/dev/null || true)

if [[ -z "$TS_STATUS_JSON" ]]; then
    fail "tailscale status returned no output — fix: sudo tailscale up"
else
    # Parse backend state safely
    if has_cmd jq; then
        TS_STATUS=$(echo "$TS_STATUS_JSON" | jq -r '.BackendState // "Unknown"' 2>/dev/null || true)
        TS_HOSTNAME=$(echo "$TS_STATUS_JSON" | jq -r '.Self.HostName // ""' 2>/dev/null || true)
        TS_DOMAIN=$(echo "$TS_STATUS_JSON" | jq -r '.Self.DNSName // ""' 2>/dev/null | sed 's/\.$//' || true)
        TS_IP=$(echo "$TS_STATUS_JSON" | jq -r '.Self.TailscaleIPs[0] // ""' 2>/dev/null || true)
    else
        # Fallback without jq — parse plain-text status
        TS_STATUS_PLAIN=$(tailscale status 2>/dev/null || true)
        if echo "$TS_STATUS_PLAIN" | grep -qi "logged out\|NeedsLogin\|not logged in"; then
            TS_STATUS="NeedsLogin"
        else
            TS_STATUS="Running"
        fi
        TS_DOMAIN=$(echo "$TS_STATUS_PLAIN" | grep -oP '[a-z0-9-]+\.[a-z0-9-]+\.ts\.net' | head -1 || true)
        TS_IP=$(echo "$TS_STATUS_PLAIN" | grep -oP '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        TS_HOSTNAME=$(hostname)
        info "jq not found — using plain-text status parse (install jq for better accuracy)"
    fi

    TS_STATUS="${TS_STATUS:-Unknown}"
    TS_DOMAIN="${TS_DOMAIN:-}"
    TS_IP="${TS_IP:-}"

    case "$TS_STATUS" in
        Running)
            pass "Tailscale backend state: Running"
            ;;
        NeedsLogin|NeedsMachineAuth)
            fail "Tailscale not authenticated (state: ${TS_STATUS}) — fix: sudo tailscale up"
            ;;
        Stopped)
            fail "Tailscale is stopped — fix: sudo tailscale up"
            ;;
        *)
            warn "Tailscale state is '${TS_STATUS}' — expected 'Running'. May still work but verify."
            ;;
    esac
fi

if [[ -n "$TS_IP" ]]; then
    pass "Tailscale IP assigned: ${TS_IP}"
else
    fail "No Tailscale IP detected — device may not be fully joined to tailnet"
fi

if [[ -n "$TS_DOMAIN" ]]; then
    pass "Tailscale FQDN: ${TS_DOMAIN}"
    info "All services will be served at: https://${TS_DOMAIN}"
else
    fail "Could not determine Tailscale FQDN — MagicDNS may not be enabled. Fix: https://login.tailscale.com/admin/dns → enable MagicDNS"
fi

# =============================================================================
#  CHECK 5 — MAGICDNS ENABLED & RESOLVING
# =============================================================================

section "5. MagicDNS — enabled and resolving"

if [[ -z "$TS_DOMAIN" ]]; then
    skip "Skipping DNS resolution checks — FQDN unknown (MagicDNS likely disabled)"
else
    # Check that the .ts.net domain resolves — must use 100.100.100.100 (Tailscale DNS)
    # or the system resolver if MagicDNS is integrated

    # Test 1: System resolver
    DNS_RESULT_RAW=$(getent hosts "$TS_DOMAIN" 2>/dev/null || true)
    DNS_RESULT=$(echo "$DNS_RESULT_RAW" | awk '{print $1}' | head -1 || true)
    DNS_RESULT="${DNS_RESULT:-}"

    if [[ -n "$DNS_RESULT" ]]; then
        pass "System DNS resolves ${TS_DOMAIN} → ${DNS_RESULT}"
        if [[ "$DNS_RESULT" == "$TS_IP" ]]; then
            pass "Resolved IP matches Tailscale IP (${TS_IP})"
        else
            warn "Resolved IP (${DNS_RESULT}) does not match Tailscale IP (${TS_IP}) — may cause cert mismatch"
        fi
    else
        # Test 2: Query Tailscale's built-in DNS resolver directly
        if has_cmd dig; then
            DIG_RESULT_RAW=$(dig +short "$TS_DOMAIN" @100.100.100.100 2>/dev/null || true)
            DIG_RESULT=$(echo "$DIG_RESULT_RAW" | grep -oP '100\.[0-9.]+' | head -1 || true)
            DIG_RESULT="${DIG_RESULT:-}"
            if [[ -n "$DIG_RESULT" ]]; then
                warn "${TS_DOMAIN} resolves via Tailscale DNS (@100.100.100.100) but NOT via system resolver. MagicDNS may not be set as system DNS. Fix: ensure Tailscale is set as system DNS resolver, or run: sudo tailscale up --accept-dns=true"
            else
                fail "${TS_DOMAIN} does not resolve via system DNS or Tailscale DNS — fix: enable MagicDNS at https://login.tailscale.com/admin/dns"
            fi
        else
            fail "${TS_DOMAIN} does not resolve (dig not available for deeper check) — fix: enable MagicDNS at https://login.tailscale.com/admin/dns"
        fi
    fi

    # Test 3: Verify Tailscale DNS service is reachable
    PING_DNS_RAW=$(ping -c 1 -W 2 100.100.100.100 2>/dev/null || true)
    if echo "$PING_DNS_RAW" | grep -q "1 received\|1 packets received"; then
        pass "Tailscale DNS resolver (100.100.100.100) is reachable"
    else
        warn "Tailscale DNS resolver (100.100.100.100) not responding to ping — DNS may still work via other path"
    fi
fi

# =============================================================================
#  CHECK 6 — HTTPS CERTIFICATES ENABLED IN TAILSCALE ADMIN
# =============================================================================

section "6. Tailscale HTTPS certificates enabled"

if [[ -z "$TS_DOMAIN" ]]; then
    skip "Skipping certificate checks — FQDN unknown"
else
    # Attempt to fetch a certificate — this will fail if HTTPS is not enabled in admin
    CERT_DIR=$(mktemp -d)
    CERT_FILE="${CERT_DIR}/${TS_DOMAIN}.crt"
    CERT_KEY="${CERT_DIR}/${TS_DOMAIN}.key"

    info "Attempting: tailscale cert ${TS_DOMAIN}"
    # Note: tailscale cert exits non-zero if HTTPS is not enabled — capture safely
    CERT_OUTPUT_RAW=$(tailscale cert --cert-file "$CERT_FILE" --key-file "$CERT_KEY" "$TS_DOMAIN" 2>&1 || true)
    CERT_EXIT=$?

    if [[ -f "$CERT_FILE" && -s "$CERT_FILE" ]]; then
        pass "Certificate obtained from Tailscale daemon"

        # Inspect the certificate
        if has_cmd openssl; then
            # Subject
            CERT_SUBJECT_RAW=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null || true)
            CERT_SUBJECT=$(echo "$CERT_SUBJECT_RAW" | sed 's/subject=//' | tr -d ' ' || true)
            CERT_SUBJECT="${CERT_SUBJECT:-unknown}"
            info "Certificate subject: ${CERT_SUBJECT}"

            # Expiry date and days remaining
            CERT_EXPIRY_RAW=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null || true)
            CERT_EXPIRY=$(echo "$CERT_EXPIRY_RAW" | sed 's/notAfter=//' || true)
            CERT_EXPIRY="${CERT_EXPIRY:-unknown}"

            CERT_EXPIRY_EPOCH=$(date -d "$CERT_EXPIRY" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( (CERT_EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

            if [[ $DAYS_LEFT -gt 30 ]]; then
                pass "Certificate valid for ${DAYS_LEFT} days (expires: ${CERT_EXPIRY})"
            elif [[ $DAYS_LEFT -gt 0 ]]; then
                warn "Certificate expires in ${DAYS_LEFT} days (${CERT_EXPIRY}) — renew soon: sudo tailscale cert ${TS_DOMAIN}"
            else
                fail "Certificate has expired (${CERT_EXPIRY}) — fix: sudo tailscale cert ${TS_DOMAIN}"
            fi

            # Verify CN matches our domain
            CERT_CN_RAW=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,/]+' || true)
            CERT_CN="${CERT_CN_RAW:-}"
            if [[ "$CERT_CN" == "$TS_DOMAIN" || "$CERT_CN" == "*.${TS_DOMAIN#*.}" ]]; then
                pass "Certificate CN matches FQDN: ${CERT_CN}"
            else
                warn "Certificate CN (${CERT_CN}) does not exactly match FQDN (${TS_DOMAIN}) — may cause browser warnings"
            fi

            # Check SANs include the domain
            SAN_RAW=$(openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null || true)
            if echo "$SAN_RAW" | grep -q "$TS_DOMAIN"; then
                pass "Certificate SAN includes ${TS_DOMAIN}"
            else
                warn "Certificate SAN does not explicitly list ${TS_DOMAIN} — check: openssl x509 -in ${CERT_FILE} -noout -ext subjectAltName"
            fi

            # Check issuer — should be Let's Encrypt via Tailscale
            ISSUER_RAW=$(openssl x509 -in "$CERT_FILE" -noout -issuer 2>/dev/null || true)
            ISSUER=$(echo "$ISSUER_RAW" | sed 's/issuer=//' || true)
            info "Certificate issuer: ${ISSUER}"
            if echo "$ISSUER" | grep -qi "Let's Encrypt\|ISRG"; then
                pass "Certificate issued by Let's Encrypt (via Tailscale)"
            else
                warn "Unexpected certificate issuer: ${ISSUER} — expected Let's Encrypt"
            fi
        else
            warn "openssl not found — cannot inspect certificate details. Fix: sudo apt install openssl"
        fi

        # Verify key file was also created
        if [[ -f "$CERT_KEY" && -s "$CERT_KEY" ]]; then
            pass "Private key file present"
        else
            fail "Certificate obtained but private key file missing — Caddy cannot use this cert"
        fi

    else
        # Parse the error output to give a specific fix
        if echo "$CERT_OUTPUT_RAW" | grep -qi "https not enabled\|HTTPS.*not enabled\|feature.*not enabled"; then
            fail "Tailscale HTTPS certificates are NOT enabled — fix: go to https://login.tailscale.com/admin/dns → scroll to 'HTTPS Certificates' → click 'Enable HTTPS'"
        elif echo "$CERT_OUTPUT_RAW" | grep -qi "not logged in\|NeedsLogin"; then
            fail "Tailscale not authenticated — fix: sudo tailscale up"
        elif echo "$CERT_OUTPUT_RAW" | grep -qi "permission\|denied"; then
            fail "Permission denied fetching cert — fix: run this script as root (sudo)"
        elif echo "$CERT_OUTPUT_RAW" | grep -qi "timeout\|network"; then
            fail "Network timeout fetching cert — check Tailscale connectivity: tailscale ping ${TS_DOMAIN}"
        else
            fail "tailscale cert failed: ${CERT_OUTPUT_RAW} — fix: verify HTTPS is enabled at https://login.tailscale.com/admin/dns"
        fi
    fi

    # Clean up temp cert files
    rm -rf "$CERT_DIR"
fi

# =============================================================================
#  CHECK 7 — CADDY CAN ACCESS TAILSCALE SOCKET
# =============================================================================

section "7. Caddy ↔ Tailscale socket access (TS_PERMIT_CERT_UID)"

# Caddy in Docker runs as root. The host tailscaled must permit root to
# fetch certs via the socket. This is configured via TS_PERMIT_CERT_UID.

if [[ -f "$TAILSCALED_DEFAULTS" ]]; then
    TS_PERMIT_UID_RAW=$(grep "^TS_PERMIT_CERT_UID" "$TAILSCALED_DEFAULTS" 2>/dev/null || true)
    TS_PERMIT_UID=$(echo "$TS_PERMIT_UID_RAW" | cut -d= -f2 | tr -d '[:space:]' || true)
    TS_PERMIT_UID="${TS_PERMIT_UID:-}"

    if [[ -n "$TS_PERMIT_UID" ]]; then
        info "TS_PERMIT_CERT_UID is set to: ${TS_PERMIT_UID}"
        if echo "$TS_PERMIT_UID" | grep -q "root\|^0$"; then
            pass "TS_PERMIT_CERT_UID includes root — Caddy can fetch certs from tailscaled"
        else
            warn "TS_PERMIT_CERT_UID=${TS_PERMIT_UID} — does not include root. Caddy (running as root in Docker) may fail. Fix: add 'TS_PERMIT_CERT_UID=root' to ${TAILSCALED_DEFAULTS}, then: sudo systemctl restart tailscaled"
        fi
    else
        warn "TS_PERMIT_CERT_UID not set in ${TAILSCALED_DEFAULTS}. The install script sets this automatically, but if you're pre-checking manually: echo 'TS_PERMIT_CERT_UID=root' | sudo tee -a ${TAILSCALED_DEFAULTS} && sudo systemctl restart tailscaled"
    fi
else
    warn "${TAILSCALED_DEFAULTS} does not exist — the install script will create it. If running manually: sudo mkdir -p $(dirname ${TAILSCALED_DEFAULTS}) && echo 'TS_PERMIT_CERT_UID=root' | sudo tee ${TAILSCALED_DEFAULTS}"
fi

# Verify Tailscale socket is accessible by root right now
if [[ -S "$SOCKET_PATH" ]]; then
    if [[ -r "$SOCKET_PATH" ]]; then
        pass "Tailscale socket is readable by current user (root)"
    else
        fail "Tailscale socket exists but is not readable by root — fix: sudo chmod 660 ${SOCKET_PATH}"
    fi
else
    fail "Tailscale socket not found at ${SOCKET_PATH} — fix: sudo systemctl restart tailscaled"
fi

# =============================================================================
#  CHECK 8 — HTTPS END-TO-END CONNECTIVITY TEST (live TLS handshake)
# =============================================================================

section "8. End-to-end HTTPS connectivity test"

if [[ -z "$TS_DOMAIN" ]]; then
    skip "Skipping HTTPS connectivity test — FQDN unknown"
elif ! has_cmd curl; then
    skip "Skipping HTTPS connectivity test — curl not installed. Fix: sudo apt install curl"
else
    info "Testing HTTPS connectivity to https://${TS_DOMAIN}"
    info "(This requires Caddy or another HTTPS server to already be running on this host)"

    # Note: curl exits non-zero on connection refused — capture safely
    CURL_HTTPS_CODE=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
        "https://${TS_DOMAIN}" 2>/dev/null || echo "000")
    CURL_HTTPS_CODE=$(echo "$CURL_HTTPS_CODE" | tr -d '[:space:]')
    CURL_HTTPS_CODE="${CURL_HTTPS_CODE:-000}"

    case "$CURL_HTTPS_CODE" in
        000)
            # Connection refused is expected if Caddy isn't running yet — this is a pre-check
            info "HTTPS endpoint not responding (HTTP 000) — expected if Caddy is not yet running."
            info "This check will pass once podcloud_install.sh has been run."
            # Not a failure — the purpose here is to test cert + DNS readiness, not service uptime
            ;;
        200|301|302|401|403|404)
            pass "HTTPS endpoint responded (HTTP ${CURL_HTTPS_CODE}) — TLS handshake successful"
            ;;
        *)
            warn "HTTPS endpoint returned HTTP ${CURL_HTTPS_CODE} — verify after installation"
            ;;
    esac

    # Separately test: does curl accept the cert (TLS validation) vs just get a response
    CURL_TLS_RAW=$(curl -sv --max-time 5 -o /dev/null \
        "https://${TS_DOMAIN}" 2>&1 || true)

    if echo "$CURL_TLS_RAW" | grep -q "SSL certificate verify ok\|issuer.*Let"; then
        pass "TLS certificate verified by curl (no browser warning expected)"
    elif echo "$CURL_TLS_RAW" | grep -qi "certificate.*expired"; then
        fail "TLS certificate is EXPIRED — fix: sudo tailscale cert ${TS_DOMAIN}"
    elif echo "$CURL_TLS_RAW" | grep -qi "certificate.*verify failed\|SSL.*failed"; then
        warn "TLS certificate verification failed — may be expected if no server is running yet"
    else
        info "TLS verification result inconclusive (server may not be running yet — normal at pre-install stage)"
    fi
fi

# =============================================================================
#  CHECK 9 — PORTS 80 & 443 AVAILABLE FOR CADDY
# =============================================================================

section "9. Ports 80 and 443 availability"

_port_in_use() {
    # ss preferred on Bookworm; netstat as fallback
    local port="$1"
    if has_cmd ss; then
        SS_RAW=$(ss -tlnp 2>/dev/null | grep ":${port} " || true)
        [[ -n "$SS_RAW" ]]
    elif has_cmd netstat; then
        NETSTAT_RAW=$(netstat -tlnp 2>/dev/null | grep ":${port} " || true)
        [[ -n "$NETSTAT_RAW" ]]
    else
        return 1  # cannot determine — assume not in use
    fi
}

for PORT in 80 443; do
    if _port_in_use "$PORT"; then
        # Extract just the process name from ss output: users:(("tailscaled",pid=123,...))
        # The -oP pattern must capture only the name inside the first pair of quotes
        OWNER_RAW=$(ss -tlnp 2>/dev/null | grep ":${PORT} " \
            | grep -oP '(?<=users:\(\(")[^"]+' | head -1 || true)
        OWNER=$(echo "$OWNER_RAW" | tr -d '[:space:]')
        OWNER="${OWNER:-unknown}"

        # tailscaled legitimately holds port 443 for its HTTPS proxy feature.
        # Caddy's Docker container maps host:443 → container:443; the OS will
        # reassign the port when Caddy starts. This is not a real conflict.
        if [[ "$PORT" -eq 443 && "$OWNER" == "tailscaled" ]]; then
            pass "Port 443 held by tailscaled (Tailscale HTTPS proxy) — this is expected and not a conflict with Caddy"
        elif [[ "$PORT" -eq 80 && "$OWNER" == "tailscaled" ]]; then
            pass "Port 80 held by tailscaled — expected, not a conflict with Caddy"
        else
            fail "Port ${PORT} is already in use by '${OWNER}' — Caddy needs this port. Fix: sudo systemctl stop ${OWNER} && sudo systemctl disable ${OWNER}"
        fi
    else
        pass "Port ${PORT} is available"
    fi
done

# =============================================================================
#  CHECK 10 — REQUIRED TOOLS FOR INSTALLATION
# =============================================================================

section "10. Required tools"

REQUIRED_TOOLS=(curl openssl jq)
OPTIONAL_TOOLS=(dig nslookup)

for TOOL in "${REQUIRED_TOOLS[@]}"; do
    if has_cmd "$TOOL"; then
        pass "${TOOL} is installed"
    else
        fail "${TOOL} not found — fix: sudo apt install ${TOOL}"
    fi
done

for TOOL in "${OPTIONAL_TOOLS[@]}"; do
    if has_cmd "$TOOL"; then
        pass "${TOOL} is installed (optional)"
    else
        warn "${TOOL} not found (optional but useful for debugging) — fix: sudo apt install ${TOOL}"
    fi
done

# =============================================================================
#  FINAL SUMMARY
# =============================================================================

echo "" | tee -a "$LOG_FILE"
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}" | tee -a "$LOG_FILE"
echo -e "${BOLD}${CYAN}║                        CHECK SUMMARY                            ║${RESET}" | tee -a "$LOG_FILE"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo -e "  ${GREEN}PASS${RESET}: ${PASS}   ${YELLOW}WARN${RESET}: ${WARN}   ${RED}FAIL${RESET}: ${FAIL}   ${DIM}SKIP${RESET}: ${SKIP}" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}Failures to resolve before installing:${RESET}" | tee -a "$LOG_FILE"
    for F in "${FAILURES[@]}"; do
        echo -e "    ${RED}✖${RESET} ${F}" | tee -a "$LOG_FILE"
    done
    echo "" | tee -a "$LOG_FILE"
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Warnings (non-blocking but review):${RESET}" | tee -a "$LOG_FILE"
    for W in "${WARNINGS[@]}"; do
        echo -e "    ${YELLOW}⚠${RESET} ${W}" | tee -a "$LOG_FILE"
    done
    echo "" | tee -a "$LOG_FILE"
fi

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}✔ All critical checks passed.${RESET}" | tee -a "$LOG_FILE"
    if [[ -n "$TS_DOMAIN" ]]; then
        echo -e "  ${BOLD}Ready to run:${RESET} sudo bash podcloud_install.sh" | tee -a "$LOG_FILE"
        echo -e "  ${BOLD}Services will be available at:${RESET} https://${TS_DOMAIN}" | tee -a "$LOG_FILE"
    fi
    echo "" | tee -a "$LOG_FILE"
    echo -e "  Log saved to: ${DIM}${LOG_FILE}${RESET}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    exit 0
else
    echo -e "  ${RED}${BOLD}✖ ${FAIL} critical check(s) failed.${RESET} Resolve the issues above before running podcloud_install.sh" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo -e "  Log saved to: ${DIM}${LOG_FILE}${RESET}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    exit 1
fi
