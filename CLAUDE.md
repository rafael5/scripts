# Claude Context — Shared Bash Scripts

## What this is
Shared bash utility scripts available to all projects on this machine.
`~/scripts/bin/` is on $PATH — scripts here are callable by name from anywhere.
`~/scripts/lib/` contains sourced helper libraries (not executed directly).

## Conventions
- Target: bash 5.x, Linux Mint (Debian-based, aarch64 or x86_64)
- Strict mode: `set -euo pipefail` in all executable scripts
- Source lib scripts with: `source "$HOME/scripts/lib/logging.sh"`
- All scripts must be idempotent (safe to run more than once)
- No hardcoded paths — use $HOME, not /home/rafael

## Adding a new script
1. Write it in ~/scripts/bin/
2. `chmod +x ~/scripts/bin/myscript.sh`
3. Test it: run it directly, verify idempotency by running twice
4. Commit to git
