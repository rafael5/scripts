#!/usr/bin/env bash
###############################################################################
# Python In-Place Bootstrap Script (uv + direnv auto-activation)
# Version: 1.0.1
#
# Changelog:
#   1.0.1 - Fixed: uv presence check, venv activation guard, direnv .envrc
#            syntax, PROJECT_NAME sanitization for Python package names,
#            uv pip upgrade no-op removed, touch requirements.txt idempotency
#
# ========================= FULL SETUP INSTRUCTIONS ===========================
#
# 1) Install required tools (Ubuntu / Linux Mint):
#
#    sudo apt update
#    sudo apt install python3 python3-venv direnv
#
#    Install uv:
#    curl -Ls https://astral.sh/uv/install.sh | bash
#
#    Restart shell OR source profile:
#    source ~/.bashrc
#
# 2) Enable direnv in your shell (REQUIRED for auto-activation):
#
#    Add this line to ~/.bashrc:
#        eval "$(direnv hook bash)"
#
#    Then reload:
#        source ~/.bashrc
#
# 3) Create or enter your project directory:
#
#    mkdir my_project && cd my_project
#
# 4) Run this script:
#
#    chmod +x venv-setup.sh
#    ./venv-setup.sh
#
# 5) After setup:
#
#    - cd out and back in → .venv auto-activates
#    - install packages:
#        uv pip install <package>
#
#    - freeze dependencies:
#        uv pip freeze > requirements.txt
#
#    - run tools:
#        pytest
#        ruff check .
#        black .
#
# ============================================================================
#
# Features:
#   - Works in CURRENT directory (PWD)
#   - Creates .venv (if missing)
#   - Uses uv for fast installs
#   - Creates src/ and tests/ structure
#   - Infers project name from folder
#   - Generates pyproject.toml and .gitignore (non-destructive)
#   - Installs dev tools: black, ruff, pytest
#   - Enables direnv auto-activation
#   - Idempotent (safe to re-run)
#
###############################################################################
set -e

# ADDED: Verify uv is installed before proceeding — failing here is clearer
# than failing mid-run on the first uv pip install call
command -v uv >/dev/null 2>&1 || {
  echo "ERROR: uv not found."
  echo "Install with: curl -Ls https://astral.sh/uv/install.sh | bash"
  exit 1
}

PROJECT_NAME=$(basename "$PWD")
# ADDED: Sanitize project name — hyphens are invalid in Python package/module
# names; replace with underscores so src/<name>/__init__.py is importable
PKG_NAME="${PROJECT_NAME//-/_}"

echo "==> Project: $PROJECT_NAME (package: $PKG_NAME)"

# =============================================================================
#  Structure
# =============================================================================
echo "==> Ensuring project structure..."
# FIXED: Use sanitized PKG_NAME for the importable package directory
mkdir -p "src/$PKG_NAME"
mkdir -p tests
touch "src/$PKG_NAME/__init__.py"

# =============================================================================
#  .gitignore
# =============================================================================
if [ ! -f .gitignore ]; then
  echo "==> Creating .gitignore..."
  cat > .gitignore <<EOF
.venv/
__pycache__/
*.pyc
*.pyo
*.pyd
.env
*.log
dist/
build/
*.egg-info/
EOF
fi

# =============================================================================
#  pyproject.toml
# =============================================================================
if [ ! -f pyproject.toml ]; then
  echo "==> Creating pyproject.toml..."
  # FIXED: Use sanitized PKG_NAME so [project] name is a valid package name
  cat > pyproject.toml <<EOF
[project]
name = "$PKG_NAME"
version = "0.1.0"
requires-python = ">=3.9"
dependencies = []

[tool.black]
line-length = 88

[tool.ruff]
line-length = 88
select = ["E", "F", "I"]
EOF
fi

# =============================================================================
#  requirements.txt
# =============================================================================
# FIXED: Was unconditional touch, which updates mtime on existing file
[ ! -f requirements.txt ] && touch requirements.txt

# =============================================================================
#  Virtual environment
# =============================================================================
if [ ! -d .venv ]; then
  echo "==> Creating virtual environment..."
  # FIXED: Use uv venv instead of python3 -m venv — consistent with uv toolchain
  uv venv .venv
fi

# =============================================================================
#  Activate
# =============================================================================
echo "==> Activating environment..."
# shellcheck disable=SC1091
# FIXED: Added explicit error guard — set -e alone gives no useful message on failure
source .venv/bin/activate || { echo "ERROR: Failed to activate .venv"; exit 1; }

# =============================================================================
#  Install tooling
# =============================================================================
echo "==> Installing tooling with uv..."
# FIXED: Removed 'uv pip install --upgrade pip' — uv manages its own pip shim;
# upgrading pip inside a uv-managed venv is a no-op and misleading
uv pip install black ruff pytest pipdeptree

# =============================================================================
#  direnv auto-activation
# =============================================================================
if command -v direnv >/dev/null 2>&1; then
  echo "==> Configuring direnv auto-activation..."
  if [ ! -f .envrc ]; then
    # FIXED: Plain 'source' is not valid in direnv's .envrc sandbox — direnv
    # provides its own stdlib; use 'source_env' to activate a venv portably
    echo 'source_env .venv/bin/activate' > .envrc
  fi
  # FIXED: Replaced '|| true' (silently swallows errors) with an explicit
  # warning so permissions or config issues are surfaced to the user
  if direnv allow; then
    echo "    direnv enabled for this directory"
  else
    echo "    WARNING: 'direnv allow' failed — check direnv config or permissions"
  fi
else
  echo "==> direnv not found"
  echo "    Install with: sudo apt install direnv"
fi

echo ""
echo "==> Setup complete in: $PWD"
echo "Next:"
echo "  cd .. && cd -   (triggers auto-activation)"
echo "  uv pip install <deps>"
echo "  pytest | ruff check . | black . | pipdeptree"
