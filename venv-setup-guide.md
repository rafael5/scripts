# venv-setup — Guide

## Purpose

Bootstrap a Python project environment in the current directory using `uv` for
package management and `direnv` for automatic virtual environment activation.
Creates the standard project layout, configuration files, and installs core dev
tools in a single run.

## Design

Runs entirely in `$PWD` — there is no target directory argument. The project name
is inferred from the current folder name, with hyphens converted to underscores
for a valid Python package name.

Each section checks whether its target already exists before acting, making the
script fully idempotent. Re-running after installing additional packages or
editing `pyproject.toml` is safe — only missing pieces are created.

`uv` is used throughout instead of `pip`/`virtualenv` for faster, reproducible
installs. `direnv` handles auto-activation so the venv becomes active whenever
you `cd` into the project directory.

## Features

- Infers project and package name from `$PWD` (hyphens → underscores)
- Creates `src/<pkg>/` and `tests/` layout
- Generates `pyproject.toml` with black and ruff config
- Generates `.gitignore` covering common Python artifacts
- Creates `.venv` with `uv venv`
- Installs dev tools: `black`, `ruff`, `pytest`, `pipdeptree`
- Configures `direnv` with `source_env .venv/bin/activate`
- `set -e` — aborts on any error
- Idempotent: checks existence before creating each artifact

## Functions

No extracted functions — sequential inline sections:

| Section | Action |
|---------|--------|
| uv check | Abort with instructions if `uv` is not installed |
| Structure | `mkdir -p src/$PKG_NAME tests/` + `touch __init__.py` |
| `.gitignore` | Write if absent |
| `pyproject.toml` | Write with project name, black/ruff config, if absent |
| `requirements.txt` | Touch if absent |
| `.venv` | `uv venv .venv` if absent |
| Activate | `source .venv/bin/activate` |
| Install | `uv pip install black ruff pytest pipdeptree` |
| direnv | Write `.envrc` if absent, run `direnv allow` |

## Use

```bash
# Create or enter the project directory first
mkdir my-project && cd my-project

# Run bootstrap
venv-setup.sh
```

After setup:
```bash
# Re-enter to trigger direnv auto-activation
cd .. && cd my-project

# Install project dependencies
uv pip install <package>

# Freeze to requirements.txt
uv pip freeze > requirements.txt

# Run dev tools
pytest
ruff check .
black .
pipdeptree
```

## Prerequisites

```bash
# Install system packages
sudo apt install python3 python3-venv direnv

# Install uv
curl -Ls https://astral.sh/uv/install.sh | bash

# Enable direnv in shell (add to ~/.bashrc)
eval "$(direnv hook bash)"
source ~/.bashrc
```

## Dependencies

| Tool | Source |
|------|--------|
| `python3` | `sudo apt install python3` |
| `uv` | `curl -Ls https://astral.sh/uv/install.sh \| bash` |
| `direnv` | `sudo apt install direnv` |
