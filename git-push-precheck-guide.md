# git-push-precheck — Guide

## Purpose

Run a pre-push safety checklist inside a git repository before pushing to a
remote. Catches common problems that cause failed pushes or pollute the remote:
diverged branches, uncommitted changes, stray dotfiles, and large untracked files
that should go through Git LFS.

## Design

A linear checklist script — each numbered check is independent and the script
always runs all of them (no early exit). Problems are reported with ⚠ warnings;
the user decides whether to fix them before pushing. Interactive prompts are used
only for destructive actions (removing `.DS_Store` files).

Two sync-check modes are provided via a `FAST_MODE` toggle at the top of the
script:
- **Fast mode (default):** `git ls-remote` — checks the remote hash without a
  full fetch. Works offline-adjacent but can miss recent remote commits if the
  network was unavailable during the last pull.
- **Full mode:** `git fetch` — guaranteed accurate, costs one network round-trip.

## Features

- Detects SSH vs HTTPS remote authentication
- Shows current branch name
- Checks whether local is ahead/behind remote (fast or full fetch mode)
- Scans for uncommitted staged and unstaged changes
- Finds common junk files: `.DS_Store`, `.venv`, `env`, `venv`
- Offers interactive removal of `.DS_Store` files
- Lists files larger than 50 MB with size and LFS tracking status
- Provides step-by-step remediation instructions for untracked large files

## Functions

The script has no extracted functions — each check is a numbered inline block:

| Check | What it does |
|-------|-------------|
| 0 — Auth | `git remote get-url origin` → SSH or HTTPS |
| 1 — Branch | `git branch --show-current` |
| 2 — Sync | Compare local and remote HEAD hashes (fast or full mode) |
| 3 — Uncommitted | `git diff` + `git diff --cached` |
| 4 — Dotfiles | `find` for `.DS_Store`, `.venv`, `env`, `venv` with optional removal |
| 5 — Large files | `find -size +50M`, cross-reference with `git lfs track` |

## Use

```bash
# Run from inside any git repository
cd /path/to/repo
git-push-precheck.sh
```

The script reads and reports; the only interactive action is the `.DS_Store`
removal prompt (responds to `y`/`Y`).

## Configuration

Edit the toggle at the top of the file:

```bash
FAST_MODE=true   # false = full git fetch before comparison
```

## Notes

- Must be run from inside the target git repository (uses `git` commands that
  rely on the working directory)
- Does not block or automate the push — it informs and lets you decide
- Large-file threshold is hardcoded at 50 MB; edit `+50M` in the `find` call
  to change it
