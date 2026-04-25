#!/bin/bash
# =============================================================================
#  install-go.sh
#  Version: 1.0.0
#  Target:  Linux x86_64 / arm64 (Mint, Ubuntu, Debian)
#
#  Purpose
#  Install or upgrade the official Go toolchain to /usr/local/go and set up
#  Rafael's Go development environment (PATH + dev tools used by the Go
#  project template at ~/claude/templates/go/).
#
#  Design
#  Idempotent installer. Downloads the official tarball from go.dev with
#  SHA-256 verification, replaces /usr/local/go atomically (via sudo), adds
#  PATH lines to ~/.bashrc only if missing, then installs the dev tools the
#  template's Makefile expects (golangci-lint, govulncheck, gotestsum) into
#  ~/go/bin. Safe to re-run to upgrade. Will not install if the requested
#  version is already at /usr/local/go.
#
#  Features
#  - Auto-detects amd64 / arm64
#  - Pulls latest stable Go from https://go.dev/VERSION?m=text by default
#  - Override version with: GO_VERSION=go1.24.2 install-go.sh
#  - Verifies SHA-256 against go.dev/dl/?mode=json before extracting
#  - Adds PATH lines to ~/.bashrc only if missing
#  - Reports versions of all installed tools at the end
#
#  Steps
#  1  Detect platform (linux/amd64 or linux/arm64)
#  2  Resolve target Go version (env GO_VERSION or fetch latest stable)
#  3  Skip download if /usr/local/go already at that version
#  4  Download tarball to /tmp
#  5  Verify checksum
#  6  Remove old /usr/local/go and extract new (sudo)
#  7  Add /usr/local/go/bin and ~/go/bin to ~/.bashrc PATH if missing
#  8  Install dev tools: golangci-lint, govulncheck, gotestsum
#  9  Print versions
#
#  Use
#  install-go.sh                       # latest stable Go
#  GO_VERSION=go1.24.2 install-go.sh   # pinned version
# =============================================================================

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

say()  { echo -e "${BOLD}==>${RESET} $*"; }
ok()   { echo -e "${GREEN}OK${RESET}  $*"; }
warn() { echo -e "${YELLOW}!!${RESET}  $*"; }
die()  { echo -e "${RED}ERROR${RESET} $*" >&2; exit 1; }

# Safety
[[ $EUID -eq 0 ]] && die "Do not run as root. The script invokes sudo where needed."
command -v curl     >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
command -v tar      >/dev/null || die "tar is required"
command -v sudo     >/dev/null || die "sudo is required"
command -v python3  >/dev/null || die "python3 is required (for JSON parsing)"

# -----------------------------------------------------------------------------
# 1. Detect platform
# -----------------------------------------------------------------------------
case "$(uname -m)" in
    x86_64)         GOARCH=amd64 ;;
    aarch64|arm64)  GOARCH=arm64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac
PLAT="linux-${GOARCH}"
say "Platform: ${PLAT}"

# -----------------------------------------------------------------------------
# 2. Resolve target version
# -----------------------------------------------------------------------------
if [[ -n "${GO_VERSION:-}" ]]; then
    VER="$GO_VERSION"
    say "Using pinned Go version: $VER"
else
    say "Fetching latest stable Go version from go.dev ..."
    VER=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n 1) \
        || die "could not reach go.dev"
    say "Latest stable: $VER"
fi
[[ "$VER" =~ ^go[0-9] ]] || die "bad version string: $VER"

# -----------------------------------------------------------------------------
# 3. Skip if already installed at that version
# -----------------------------------------------------------------------------
SKIP_INSTALL=0
if [[ -x /usr/local/go/bin/go ]]; then
    CURRENT=$(/usr/local/go/bin/go version | awk '{print $3}')
    if [[ "$CURRENT" == "$VER" ]]; then
        ok "/usr/local/go already at $VER — skipping download"
        SKIP_INSTALL=1
    else
        say "Upgrading: $CURRENT -> $VER"
    fi
fi

# -----------------------------------------------------------------------------
# 4–6. Download, verify, install
# -----------------------------------------------------------------------------
if [[ $SKIP_INSTALL -eq 0 ]]; then
    TARBALL="${VER}.${PLAT}.tar.gz"
    URL="https://go.dev/dl/${TARBALL}"
    DEST="/tmp/${TARBALL}"

    say "Downloading $URL"
    curl -fL --progress-bar -o "$DEST" "$URL" || die "download failed"

    say "Fetching expected SHA-256 from go.dev/dl/?mode=json ..."
    EXPECTED=$(VER="$VER" TARBALL="$TARBALL" python3 - <<'PY' || true
import json, os, sys, urllib.request
ver = os.environ["VER"]
tb  = os.environ["TARBALL"]
try:
    with urllib.request.urlopen("https://go.dev/dl/?mode=json&include=all", timeout=30) as r:
        data = json.load(r)
except Exception as e:
    print(f"json fetch failed: {e}", file=sys.stderr); sys.exit(2)
for rel in data:
    if rel.get("version") == ver:
        for f in rel.get("files", []):
            if f.get("filename") == tb:
                print(f["sha256"]); sys.exit(0)
print(f"no checksum found for {tb} in {ver}", file=sys.stderr); sys.exit(3)
PY
)
    [[ -n "$EXPECTED" && "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] \
        || die "could not get a valid SHA-256 from go.dev metadata (got: ${EXPECTED:-<empty>})"

    say "Verifying checksum ..."
    ACTUAL=$(sha256sum "$DEST" | awk '{print $1}')
    if [[ "$ACTUAL" != "$EXPECTED" ]]; then
        rm -f "$DEST"
        die "checksum mismatch: got $ACTUAL, want $EXPECTED"
    fi
    ok "checksum verified ($EXPECTED)"

    say "Replacing /usr/local/go (requires sudo) ..."
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$DEST" || die "extraction failed"
    rm -f "$DEST"
    ok "/usr/local/go installed at $VER"
fi

# -----------------------------------------------------------------------------
# 7. Add PATH lines to ~/.bashrc if missing
# -----------------------------------------------------------------------------
add_bashrc_line() {
    local line="$1"
    if grep -Fxq "$line" ~/.bashrc 2>/dev/null; then
        ok "~/.bashrc already has: $line"
    else
        echo "$line" >> ~/.bashrc
        ok "added to ~/.bashrc: $line"
    fi
}
say "Updating ~/.bashrc PATH ..."
add_bashrc_line 'export PATH="/usr/local/go/bin:$PATH"'
add_bashrc_line 'export PATH="$HOME/go/bin:$PATH"'

# Make tools available in *this* shell so step 8 works without re-sourcing.
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# -----------------------------------------------------------------------------
# 8. Install dev tools (~/go/bin)
# -----------------------------------------------------------------------------
say "Installing dev tools into \$HOME/go/bin ..."
mkdir -p "$HOME/go/bin"

install_tool() {
    local pkg="$1"
    local name="$2"
    if go install "$pkg" 2>&1; then
        ok "$name installed"
    else
        warn "$name install failed — continuing"
    fi
}
install_tool 'github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest' 'golangci-lint'
install_tool 'golang.org/x/vuln/cmd/govulncheck@latest'                       'govulncheck'
install_tool 'gotest.tools/gotestsum@latest'                                  'gotestsum'

# -----------------------------------------------------------------------------
# 9. Final report
# -----------------------------------------------------------------------------
echo
say "Versions:"
printf '  %-15s ' 'go';            go version 2>/dev/null || echo "MISSING"
printf '  %-15s ' 'golangci-lint'; golangci-lint --version 2>/dev/null | head -n1 || echo "MISSING"
printf '  %-15s ' 'govulncheck';   (govulncheck -version 2>/dev/null || govulncheck --version 2>&1) | head -n1 || echo "MISSING"
printf '  %-15s ' 'gotestsum';     gotestsum --version 2>/dev/null || echo "MISSING"
echo
ok "Done."
echo "    Open a new shell (or run: source ~/.bashrc) to pick up PATH changes."
echo "    Then bootstrap a project with:"
echo "        cp -r ~/claude/templates/go ~/projects/myapp && cd ~/projects/myapp"
echo "        # ... rename per ~/claude/templates/go/CLAUDE.md ..."
echo "        make install && make check"
