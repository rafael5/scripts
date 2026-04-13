# minty-baseline-capture — Guide

## Purpose

Capture a comprehensive snapshot of the current system state on Linux Mint 22.3.
Documents what was installed, what was changed from stock, and how the system is
configured — producing a set of files that answer "what did I do to this machine?"
and serve as a reference for rebuilds or audits.

## Design

Ten sequential capture sections write output files to `~/.config/mint-baseline/`
and append structured sections to a single `baseline-report.txt`. The script is
idempotent: re-running updates all files in-place. A cached stock manifest is
downloaded once from the official Mint releases URL and reused on subsequent runs.

Two tools (`deborphan`, `debsums`) are auto-installed if missing. One sudo prompt
is issued upfront for the `debsums` config scan.

The stock-delta approach is the foundation: it downloads the official Mint 22.3
Cinnamon package manifest, compares it against the currently installed packages
using `comm`, and produces added/removed package lists. This gives a clean answer
to "what did I add beyond a fresh install?"

## Features

- Downloads and caches the official Mint 22.3 stock package manifest
- Package delta: added and removed packages vs stock
- `apt-mark` manual/auto split — distinguishes intentional installs from pulled deps
- Orphan detection via `deborphan` (auto-installed)
- `/etc` config drift via `debsums -c` (auto-installed, requires sudo)
- Enabled systemd services list
- Boot timing analysis via `systemd-analyze blame`
- Network port listeners snapshot via `ss -tlnup`
- Unattended-upgrades history
- Dotfile inventory for `chezmoi` tracking
- Markdown summary report aggregating all sections

## Sections and Output Files

| Section | Output File | Description |
|---------|-------------|-------------|
| 1. Stock delta | `added-packages.txt`, `removed-packages.txt` | Packages added/removed vs Mint 22.3 stock |
| 2. Manual vs auto | `manual-packages.txt`, `auto-packages.txt`, `manual-nonstock-packages.txt` | apt-mark install intent |
| 3. Orphans | `orphan-packages.txt`, `orphan-packages-all.txt` | Unused dependency candidates |
| 4. Config drift | `modified-configs.txt` | /etc files changed from package defaults |
| 5. Services | `enabled-services.txt` | Non-stock systemd services |
| 6. Boot timing | `boot-timing.txt` | systemd-analyze blame output |
| 7. Port listeners | `port-listeners.txt` | Active network listeners (ss -tlnup) |
| 8. Upgrade history | `upgrade-history.txt` | Unattended-upgrades log |
| 9. Dotfiles | `dotfiles-inventory.txt` | Hidden config files in $HOME |
| 10. Report | `baseline-report.txt` | Markdown summary of all sections |

## Functions

| Function | Description |
|---|---|
| `has_cmd cmd` | Returns 0 if command is on PATH |
| `linecount file` | Returns line count of a file as a clean integer |
| `require_sudo` | Warns if sudo is not available without a password |
| `ensure_cmd cmd pkg` | Installs `pkg` via apt if `cmd` is not found |
| `info/ok/warn/section` | Coloured log output helpers |

## Use

```bash
# Run as your normal user (sudo prompt appears once for debsums)
minty-baseline-capture.sh
```

Output directory: `~/.config/mint-baseline/`  
Main report: `~/.config/mint-baseline/baseline-report.txt`

Re-running updates all files — safe to run periodically to track system drift.

## Dependencies

| Tool | Source |
|------|--------|
| `wget` | `sudo apt install wget` (usually pre-installed) |
| `deborphan` | Auto-installed by the script |
| `debsums` | Auto-installed by the script |
| `apt-mark` | Built into apt (always available) |
| `ss` | Part of iproute2 (pre-installed) |
| `systemd-analyze` | Part of systemd (pre-installed) |

## Target

Linux Mint 22.3 "Zena" Cinnamon (Ubuntu 24.04 Noble base). The stock manifest
URL is hardcoded for this version; edit `MINT_VERSION` and `MINT_EDITION` at
the top of the script to target a different release.
