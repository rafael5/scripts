# Claude Context — Shared Bash Scripts

## What this is
Shared bash utility scripts available to all projects on this machine.
`~/scripts/bin/` is on $PATH — scripts here are callable by name from anywhere.
`~/scripts/lib/` contains sourced helper libraries (not executed directly).

## Conventions
- Target: bash 5.x, Linux Mint (Debian-based, aarch64 or x86_64)
- Strict mode: `set -euo pipefail` — the standard for every executable script.
  Currently 11 of 22 comply; new and touched scripts must, older ones are
  being brought up as they are edited
- Source lib helpers by path: `source "$HOME/scripts/lib/<name>.sh"`
  (present today: `engine-stack-guard.sh`, `git-status-reminder.sh` — there is
  no `logging.sh`)
- All scripts must be idempotent (safe to run more than once)
- No hardcoded paths — use $HOME, not /home/rafael

## Adding a new script
1. Write it in ~/scripts/bin/
2. `chmod +x ~/scripts/bin/myscript.sh`
3. Test it: run it directly, verify idempotency by running twice
4. Commit to git
