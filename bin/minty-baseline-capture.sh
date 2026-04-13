#!/usr/bin/env bash
# =============================================================================
#  minty-baseline-capture.sh
#  Version: 2.0.0
#  Target:  Linux Mint 22.3 "Zena" Cinnamon (Ubuntu 24.04 Noble base)
#
#  Purpose
#  Capture the full system state of a Linux Mint installation for auditing,
#  comparison, and version control. Produces a structured baseline report
#  covering packages, config drift, services, boot timing, port listeners,
#  unattended-upgrades history, and dotfile candidates.
#
#  Design
#  10-section linear scan; all output written to ~/.config/mint-baseline/.
#  Downloads the stock Mint manifest once and caches it; re-run uses the
#  cache. Missing tools (debsums, deborphan) are auto-installed. Requires
#  sudo once for the debsums config scan (prompted at start).
#
#  Features
#  - Stock delta: packages added/removed vs official Mint manifest
#  - Manual vs auto: apt-mark showmanual / showauto with intent list
#  - Orphaned deps: deborphan library scan + guess-all candidates
#  - /etc config drift: debsums -ce (modified package config files)
#  - Enabled services with non-stock detection
#  - Boot timing: systemd-analyze blame + critical-chain
#  - Port listeners: ss TCP/UDP snapshot
#  - Unattended-upgrades log (last 50 lines)
#  - Dotfile inventory for chezmoi management
#  - Full structured baseline-report.txt
#
#  Sections
#  1  Package delta vs stock manifest
#  2  Manual vs auto-installed (apt-mark)
#  3  Orphaned packages (deborphan)
#  4  /etc config drift (debsums)
#  5  Enabled services
#  6  Boot performance (systemd-analyze)
#  7  Port listeners (ss)
#  8  Unattended-upgrades history
#  9  Dotfiles inventory
#  10 Summary + next-step recommendations
#
#  Requires
#  wget, awk, sort, comm, systemctl, ss (iproute2)
#  debsums — auto-installed if missing
#  deborphan — auto-installed if missing
#  Sudo — required for debsums config scan; prompted once
#
#  Use
#  minty-baseline-capture.sh
#  Output: ~/.config/mint-baseline/baseline-report.txt
# =============================================================================

set -uo pipefail

# =============================================================================
#  CONSTANTS
# =============================================================================

MINT_VERSION="22.3"
MINT_EDITION="cinnamon"
MANIFEST_URL="https://releases.linuxmint.com/release/linuxmint-${MINT_VERSION}-${MINT_EDITION}-64bit.manifest"
BASELINE_DIR="${HOME}/.config/mint-baseline"
REPORT_FILE="${BASELINE_DIR}/baseline-report.txt"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

STOCK_SERVICE_PATTERNS="NetworkManager|cups|bluetooth|lightdm|cron|ssh|ufw|avahi|ModemManager|wpa_supplicant|systemd|dbus|getty|snapd|apt|fwupd|thermald|udisks|upower|polkit|rtkit|colord|accounts|packagekit|kerneloops|whoopsie"

YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# =============================================================================
#  HELPERS
# =============================================================================

has_cmd() { command -v "$1" >/dev/null 2>&1; }

linecount() {
    local raw
    raw=$(wc -l < "$1" 2>/dev/null || echo 0)
    echo "${raw}" | tr -d '[:space:]'
}

require_sudo() {
    if ! sudo -n true >/dev/null 2>&1; then
        warn "sudo needed for config scan — you may be prompted for your password."
    fi
}

ensure_cmd() {
    local cmd="$1" pkg="$2"
    if ! has_cmd "${cmd}"; then
        info "Installing ${pkg} (needed for this section)..."
        sudo apt-get install -y -q "${pkg}" >/dev/null 2>&1 || \
            warn "Could not install ${pkg} — skipping section."
    fi
}

# =============================================================================
#  SETUP
# =============================================================================

mkdir -p "${BASELINE_DIR}"

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        Mint 22.3 Baseline Capture  v2.0                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
info "Baseline directory : ${BASELINE_DIR}"
info "Timestamp          : ${TIMESTAMP}"
info "Host               : $(hostname)"

require_sudo
sudo -v

{
    echo "# Linux Mint 22.3 Baseline Report — v2.0"
    echo "# Generated : ${TIMESTAMP}"
    echo "# Host      : $(hostname)"
    echo ""
} > "${REPORT_FILE}"

# =============================================================================
#  1. PACKAGES — delta vs stock manifest
# =============================================================================

section "1. Packages — stock delta"

MANIFEST_FILE="${BASELINE_DIR}/stock-manifest.txt"
STOCK_PKGS="${BASELINE_DIR}/stock-packages.txt"
CURRENT_PKGS="${BASELINE_DIR}/current-packages.txt"
ADDED_PKGS="${BASELINE_DIR}/added-packages.txt"
REMOVED_PKGS="${BASELINE_DIR}/removed-packages.txt"

ADDED_COUNT=0; REMOVED_COUNT=0

if [[ ! -f "${MANIFEST_FILE}" ]]; then
    info "Downloading stock Mint ${MINT_VERSION} ${MINT_EDITION} manifest..."
    if ! wget -q "${MANIFEST_URL}" -O "${MANIFEST_FILE}"; then
        warn "Could not download manifest — check network."
        warn "URL: ${MANIFEST_URL}"
        echo "# PACKAGE SECTION: manifest download failed" >> "${REPORT_FILE}"
    fi
else
    ok "Using cached manifest: ${MANIFEST_FILE}"
fi

if [[ -f "${MANIFEST_FILE}" ]]; then
    awk '{print $1}' "${MANIFEST_FILE}" | sed 's/:.*$//' | sort -u > "${STOCK_PKGS}"
    dpkg --get-selections | awk '/\tinstall$/{print $1}' | sed 's/:.*$//' | sort -u \
        > "${CURRENT_PKGS}"
    comm -13 "${STOCK_PKGS}" "${CURRENT_PKGS}" > "${ADDED_PKGS}"
    comm -23 "${STOCK_PKGS}" "${CURRENT_PKGS}" > "${REMOVED_PKGS}"
    ADDED_COUNT=$(linecount "${ADDED_PKGS}")
    REMOVED_COUNT=$(linecount "${REMOVED_PKGS}")
    ok "Packages added beyond stock : ${ADDED_COUNT}"
    ok "Stock packages removed       : ${REMOVED_COUNT}"
    {
        echo "## 1. Package Delta vs Stock Mint ${MINT_VERSION}"
        echo "### Added (${ADDED_COUNT}):"
        cat "${ADDED_PKGS}"
        echo ""
        echo "### Removed from stock (${REMOVED_COUNT}):"
        cat "${REMOVED_PKGS}"
        echo ""
    } >> "${REPORT_FILE}"
fi

# =============================================================================
#  2. PACKAGES — manual vs auto-installed (apt-mark)
# =============================================================================

section "2. Packages — manual vs auto (apt-mark)"

MANUAL_PKGS="${BASELINE_DIR}/manual-packages.txt"
AUTO_PKGS="${BASELINE_DIR}/auto-packages.txt"
MANUAL_NONSTOCK="${BASELINE_DIR}/manual-nonstock-packages.txt"

MANUAL_COUNT=0; AUTO_COUNT=0; MANUAL_NONSTOCK_COUNT=0

apt-mark showmanual 2>/dev/null | sort > "${MANUAL_PKGS}" || true
apt-mark showauto   2>/dev/null | sort > "${AUTO_PKGS}"   || true

MANUAL_COUNT=$(linecount "${MANUAL_PKGS}")
AUTO_COUNT=$(linecount "${AUTO_PKGS}")
ok "Manually installed : ${MANUAL_COUNT}"
ok "Auto-installed deps: ${AUTO_COUNT}"

if [[ -f "${STOCK_PKGS}" ]]; then
    comm -13 "${STOCK_PKGS}" "${MANUAL_PKGS}" > "${MANUAL_NONSTOCK}" || true
    MANUAL_NONSTOCK_COUNT=$(linecount "${MANUAL_NONSTOCK}")
    ok "Intent list (manual + non-stock) : ${MANUAL_NONSTOCK_COUNT}"
else
    echo "(stock manifest unavailable)" > "${MANUAL_NONSTOCK}"
fi

{
    echo "## 2. Manual vs Auto-installed Packages"
    echo "### Manually installed (${MANUAL_COUNT} total):"
    cat "${MANUAL_PKGS}"
    echo ""
    echo "### Intent list — manually installed AND not in stock (${MANUAL_NONSTOCK_COUNT}):"
    cat "${MANUAL_NONSTOCK}"
    echo ""
    echo "### Auto-installed dependencies (${AUTO_COUNT}) — saved to auto-packages.txt"
    echo ""
} >> "${REPORT_FILE}"

# =============================================================================
#  3. PACKAGES — orphaned / unused dependencies (deborphan)
# =============================================================================

section "3. Packages — orphans (deborphan)"

ORPHAN_PKGS="${BASELINE_DIR}/orphan-packages.txt"
ORPHAN_ALL="${BASELINE_DIR}/orphan-packages-all.txt"

ORPHAN_COUNT=0; ORPHAN_ALL_COUNT=0

ensure_cmd deborphan deborphan

if has_cmd deborphan; then
    ORPHAN_RAW=$(deborphan 2>/dev/null || true)
    if [[ -n "${ORPHAN_RAW}" ]]; then
        echo "${ORPHAN_RAW}" | sort > "${ORPHAN_PKGS}"
    else
        echo "(none)" > "${ORPHAN_PKGS}"
    fi
    ORPHAN_COUNT=$(linecount "${ORPHAN_PKGS}")

    ORPHAN_ALL_RAW=$(deborphan --guess-all 2>/dev/null || true)
    if [[ -n "${ORPHAN_ALL_RAW}" ]]; then
        echo "${ORPHAN_ALL_RAW}" | sort > "${ORPHAN_ALL}"
    else
        echo "(none)" > "${ORPHAN_ALL}"
    fi
    ORPHAN_ALL_COUNT=$(linecount "${ORPHAN_ALL}")

    ok "Orphaned libraries    : ${ORPHAN_COUNT}"
    ok "All orphan candidates : ${ORPHAN_ALL_COUNT}  (review before removing)"

    {
        echo "## 3. Orphaned Packages"
        echo "### Orphaned libraries — safe removal candidates (${ORPHAN_COUNT}):"
        cat "${ORPHAN_PKGS}"
        echo ""
        echo "### All packages with no dependents — review before removing (${ORPHAN_ALL_COUNT}):"
        cat "${ORPHAN_ALL}"
        echo ""
        echo "# To remove orphaned libs: sudo apt remove \$(deborphan)"
        echo ""
    } >> "${REPORT_FILE}"
else
    warn "deborphan not available — skipping orphan scan."
fi

# =============================================================================
#  4. SYSTEM CONFIG — /etc drift (debsums)
# =============================================================================

section "4. System config (/etc drift)"

MODIFIED_CONFIGS="${BASELINE_DIR}/modified-configs.txt"
MODIFIED_COUNT=0

ensure_cmd debsums debsums

if has_cmd debsums; then
    info "Scanning /etc for modified config files (may take ~30s)..."
    DEBSUMS_RAW=$(sudo debsums -ce 2>/dev/null || true)
    if [[ -n "${DEBSUMS_RAW}" ]]; then
        echo "${DEBSUMS_RAW}" > "${MODIFIED_CONFIGS}"
        MODIFIED_COUNT=$(linecount "${MODIFIED_CONFIGS}")
        ok "Modified config files : ${MODIFIED_COUNT}"
    else
        ok "No modified config files detected."
        echo "(none)" > "${MODIFIED_CONFIGS}"
    fi
    {
        echo "## 4. Modified /etc Config Files (${MODIFIED_COUNT})"
        cat "${MODIFIED_CONFIGS}"
        echo ""
    } >> "${REPORT_FILE}"
else
    warn "debsums not available — skipping config scan."
fi

# =============================================================================
#  5. ENABLED SERVICES
# =============================================================================

section "5. Enabled services"

CURRENT_SERVICES="${BASELINE_DIR}/enabled-services.txt"
SERVICE_COUNT=0

systemctl list-unit-files --state=enabled --no-pager 2>/dev/null \
    | awk 'NR>1 && NF>=2 {print $1}' \
    | grep -v '^$' \
    | sort > "${CURRENT_SERVICES}" || true

SERVICE_COUNT=$(linecount "${CURRENT_SERVICES}")
NON_STOCK_SERVICES=$(grep -Ev "${STOCK_SERVICE_PATTERNS}" "${CURRENT_SERVICES}" || true)
ok "Enabled services : ${SERVICE_COUNT}"

{
    echo "## 5. Enabled Services (${SERVICE_COUNT} total)"
    echo "### All enabled:"
    cat "${CURRENT_SERVICES}"
    echo ""
    echo "### Likely user-added (not typical Mint defaults):"
    if [[ -n "${NON_STOCK_SERVICES}" ]]; then
        echo "${NON_STOCK_SERVICES}"
    else
        echo "(none detected)"
    fi
    echo ""
} >> "${REPORT_FILE}"

# =============================================================================
#  6. BOOT PERFORMANCE — systemd-analyze
# =============================================================================

section "6. Boot performance (systemd-analyze)"

BOOT_BLAME="${BASELINE_DIR}/boot-blame.txt"
BOOT_CRITICAL="${BASELINE_DIR}/boot-critical-chain.txt"

BLAME_RAW=$(systemd-analyze blame 2>/dev/null || true)
if [[ -n "${BLAME_RAW}" ]]; then
    echo "${BLAME_RAW}" > "${BOOT_BLAME}"
    ok "Boot units profiled : $(linecount "${BOOT_BLAME}")"
else
    echo "(unavailable)" > "${BOOT_BLAME}"
    warn "systemd-analyze blame returned no output."
fi

CRITICAL_RAW=$(systemd-analyze critical-chain 2>/dev/null || true)
if [[ -n "${CRITICAL_RAW}" ]]; then
    echo "${CRITICAL_RAW}" > "${BOOT_CRITICAL}"
    ok "Critical chain captured"
else
    echo "(unavailable)" > "${BOOT_CRITICAL}"
fi

BOOT_TOTAL_RAW=$(systemd-analyze 2>/dev/null || true)
BOOT_TOTAL=$(echo "${BOOT_TOTAL_RAW}" | head -1 | tr -d '\n' || true)

{
    echo "## 6. Boot Performance"
    echo "Total: ${BOOT_TOTAL:-unavailable}"
    echo ""
    echo "### Top 15 slowest units:"
    head -15 "${BOOT_BLAME}"
    echo ""
    echo "### Critical chain:"
    cat "${BOOT_CRITICAL}"
    echo ""
} >> "${REPORT_FILE}"

echo ""
info "Top 10 slowest boot units:"
head -10 "${BOOT_BLAME}" | while IFS= read -r line; do
    echo "    ${line}"
done

# =============================================================================
#  7. PORT LISTENERS — ss snapshot
# =============================================================================

section "7. Port listeners (ss)"

PORT_SNAPSHOT="${BASELINE_DIR}/port-listeners.txt"

TCP_LISTENERS=$(ss -tlnp 2>/dev/null || true)
UDP_LISTENERS=$(ss -ulnp 2>/dev/null || true)

{
    echo "=== TCP listeners ==="
    echo "${TCP_LISTENERS}"
    echo ""
    echo "=== UDP listeners ==="
    echo "${UDP_LISTENERS}"
} > "${PORT_SNAPSHOT}"

PORT_COUNT_RAW=$(ss -tlnp 2>/dev/null | grep -c LISTEN || echo 0)
PORT_COUNT=$(echo "${PORT_COUNT_RAW}" | tr -d '[:space:]')
ok "TCP listening ports : ${PORT_COUNT}"

{
    echo "## 7. Port Listeners"
    cat "${PORT_SNAPSHOT}"
    echo ""
} >> "${REPORT_FILE}"

# =============================================================================
#  8. UNATTENDED-UPGRADES log
# =============================================================================

section "8. Unattended-upgrades history"

UA_LOG="/var/log/unattended-upgrades/unattended-upgrades.log"
UA_SNAPSHOT="${BASELINE_DIR}/unattended-upgrades-recent.txt"
UA_PKG_COUNT="n/a"

if [[ -f "${UA_LOG}" ]]; then
    tail -50 "${UA_LOG}" > "${UA_SNAPSHOT}" 2>/dev/null || true
    ok "Unattended-upgrades log captured (last $(linecount "${UA_SNAPSHOT}") lines)"
    UA_PKG_COUNT_RAW=$(grep -c "Packages that will be upgraded:" "${UA_LOG}" 2>/dev/null || echo 0)
    UA_PKG_COUNT=$(echo "${UA_PKG_COUNT_RAW}" | tr -d '[:space:]')
    ok "Auto-upgrade runs in log : ${UA_PKG_COUNT}"
    {
        echo "## 8. Unattended-upgrades (last 50 log lines)"
        cat "${UA_SNAPSHOT}"
        echo ""
    } >> "${REPORT_FILE}"
else
    warn "No unattended-upgrades log found at ${UA_LOG}"
    echo "## 8. Unattended-upgrades: log not found" >> "${REPORT_FILE}"
fi

# =============================================================================
#  9. DOTFILES INVENTORY
# =============================================================================

section "9. Dotfiles inventory"

DOTFILES_LIST="${BASELINE_DIR}/dotfiles-inventory.txt"
DOTFILE_COUNT=0

find "${HOME}" -maxdepth 2 -name ".*" \
    ! -path "${HOME}/.cache/*" \
    ! -path "${HOME}/.local/share/recently-used*" \
    ! -path "${HOME}/.dbus/*" \
    ! -name ".bash_history" \
    2>/dev/null | sort > "${DOTFILES_LIST}" || true

DOTFILE_COUNT=$(linecount "${DOTFILES_LIST}")
ok "Dotfile candidates : ${DOTFILE_COUNT}"

{
    echo "## 9. Dotfile Candidates (${DOTFILE_COUNT}) — review and add to chezmoi"
    cat "${DOTFILES_LIST}"
    echo ""
} >> "${REPORT_FILE}"

# =============================================================================
#  10. SUMMARY
# =============================================================================

section "10. Summary"

{
    echo "## Summary"
    echo "Captured : ${TIMESTAMP}"
    echo "Host     : $(hostname)"
    echo ""
    echo "| # | Layer                    | File                           | Count           |"
    echo "|---|--------------------------|--------------------------------|-----------------|"
    printf "| 1 | Packages added (stock Δ) | added-packages.txt             | %-15s |\n" "${ADDED_COUNT}"
    printf "| 1 | Packages removed (stock) | removed-packages.txt           | %-15s |\n" "${REMOVED_COUNT}"
    printf "| 2 | Manual installs          | manual-packages.txt            | %-15s |\n" "${MANUAL_COUNT}"
    printf "| 2 | Intent list              | manual-nonstock-packages.txt   | %-15s |\n" "${MANUAL_NONSTOCK_COUNT}"
    printf "| 3 | Orphaned libs            | orphan-packages.txt            | %-15s |\n" "${ORPHAN_COUNT}"
    printf "| 3 | All orphan candidates    | orphan-packages-all.txt        | %-15s |\n" "${ORPHAN_ALL_COUNT}"
    printf "| 4 | Modified /etc files      | modified-configs.txt           | %-15s |\n" "${MODIFIED_COUNT}"
    printf "| 5 | Enabled services         | enabled-services.txt           | %-15s |\n" "${SERVICE_COUNT}"
    printf "| 6 | Boot blame               | boot-blame.txt                 | %-15s |\n" "see file"
    printf "| 7 | Port listeners           | port-listeners.txt             | %-15s |\n" "${PORT_COUNT} TCP"
    printf "| 8 | Auto-upgrade log         | unattended-upgrades-recent.txt | %-15s |\n" "see file"
    printf "| 9 | Dotfile candidates       | dotfiles-inventory.txt         | %-15s |\n" "${DOTFILE_COUNT}"
    echo ""
    echo "## Recommended Next Steps"
    echo ""
    echo "PACKAGES:"
    echo "  1. Commit manual-nonstock-packages.txt — your real intent list"
    echo "  2. Remove orphaned libs: sudo apt remove \$(deborphan)"
    echo "  3. Review orphan-packages-all.txt carefully before acting"
    echo ""
    echo "CONFIGS:"
    echo "  4. Review modified-configs.txt — add intentional changes to etckeeper"
    echo "  5. Review dotfiles-inventory.txt — add to chezmoi: chezmoi add <file>"
    echo ""
    echo "SERVICES / SECURITY:"
    echo "  6. Disable any slow boot unit you don't need (see boot-blame.txt)"
    echo "  7. Verify every open port in port-listeners.txt is intentional"
    echo ""
    echo "MAINTENANCE:"
    echo "  8. Review unattended-upgrades-recent.txt periodically"
    echo "  9. Re-run this script quarterly or after any major change session"
} >> "${REPORT_FILE}"

# =============================================================================
#  FINAL OUTPUT
# =============================================================================

echo ""
echo -e "${BOLD}Baseline files written to: ${BASELINE_DIR}/${RESET}"
echo ""
echo -e "  ${GREEN}§1${RESET}  added-packages.txt              packages added beyond stock"
echo -e "  ${GREEN}§1${RESET}  removed-packages.txt            stock packages no longer present"
echo -e "  ${GREEN}§2${RESET}  manual-packages.txt             everything apt-mark showmanual"
echo -e "  ${GREEN}§2${RESET}  manual-nonstock-packages.txt    your real intent list  ← most useful"
echo -e "  ${GREEN}§2${RESET}  auto-packages.txt               auto-installed deps (reference)"
echo -e "  ${GREEN}§3${RESET}  orphan-packages.txt             unused libs — safe to remove"
echo -e "  ${GREEN}§3${RESET}  orphan-packages-all.txt         broader orphan candidates — review first"
echo -e "  ${GREEN}§4${RESET}  modified-configs.txt            /etc files changed vs package originals"
echo -e "  ${GREEN}§5${RESET}  enabled-services.txt            all enabled systemd units"
echo -e "  ${GREEN}§6${RESET}  boot-blame.txt                  boot time per unit"
echo -e "  ${GREEN}§6${RESET}  boot-critical-chain.txt         boot critical path"
echo -e "  ${GREEN}§7${RESET}  port-listeners.txt              open TCP/UDP ports + owning process"
echo -e "  ${GREEN}§8${RESET}  unattended-upgrades-recent.txt  last 50 lines of auto-upgrade log"
echo -e "  ${GREEN}§9${RESET}  dotfiles-inventory.txt          dotfile candidates for chezmoi"
echo -e "        baseline-report.txt             full structured report"
echo ""
echo -e "${BOLD}Most important file to commit first:${RESET} manual-nonstock-packages.txt"
echo -e "${BOLD}Full report:${RESET} ${REPORT_FILE}"
echo ""
ok "Done. To version-control this snapshot:"
echo "    git -C ${BASELINE_DIR} add -A && git -C ${BASELINE_DIR} commit -m \"baseline \$(date +%F)\""
