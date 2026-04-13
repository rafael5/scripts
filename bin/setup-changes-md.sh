#!/usr/bin/env bash
# =============================================================================
#  setup-changes-md.sh
#  Version: 1.0.0
#  Target:  Linux Mint 22.3 / Ubuntu 24.04, bash 5.x
#
#  Purpose
#  Install a canonical CHANGES.md maintenance journal into existing git
#  repositories and configure git's init.templateDir so all future repos
#  receive the file automatically on git init or git clone.
#
#  Design
#  Two-phase: (1) process a hard-coded list of existing repos — create
#  CHANGES.md if absent, or prepend the intro block if the file exists but
#  lacks it; (2) write the template to ~/.config/git/template/ and set
#  git config --global init.templateDir. Idempotent — uses a sentinel string
#  to detect whether the intro block is already present before writing.
#
#  Features
#  - Creates CHANGES.md with purpose, entry format, and example entry
#  - Prepends intro to existing CHANGES.md files (non-destructive)
#  - Stages and commits CHANGES.md in each processed repo
#  - Configures git init template for all future repos
#  - Idempotent: safe to re-run; skips repos already up to date
#
#  Functions
#  changes_md_content()    Emit the canonical CHANGES.md content via heredoc
#  install_changes_md()    Create or prepend CHANGES.md in one repo directory
#  commit_if_staged()      Commit CHANGES.md if it was staged in a given repo
#
#  Use
#  setup-changes-md.sh
#  Edit EXISTING_REPOS array in the script to target different directories.
# =============================================================================

set -uo pipefail

BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# =============================================================================
#  CANONICAL CHANGES.MD CONTENT
#  Single source of truth — used for both existing repos and the git template.
# =============================================================================

# Using a function so the heredoc stays readable without quoting nightmares
changes_md_content() {
cat << 'CHANGES_EOF'
# CHANGES

## What this file is

A human-readable log of *why* things changed — intent, decisions, and context
that git diffs and commit messages can't capture on their own. Git records
what changed; this file records why it mattered.

It is not a substitute for commit messages, and not a changelog for end-users.
It is a personal maintenance journal for this repository.

## When to write an entry

- **After a meaningful work session** — one entry per session is enough, even
  if you made a dozen commits. Summarise what you were trying to do and what
  you decided.
- **When you make a non-obvious decision** — chose approach A over B, removed
  something intentionally, deferred something deliberately. Future you will
  not remember why.
- **When something broke and you fixed it** — what the symptom was, what
  caused it, how you resolved it.
- **Not required for** trivial edits (typo fixes, formatting), version bumps
  with no logic change, or anything fully self-explanatory from the commit
  message.

## Entry format

```
## YYYY-MM-DD — Short description of the session or change

What you were trying to accomplish, and any relevant context.

- Specific decision or action taken, and why
- What you tried that didn't work, if useful to record
- Anything left unfinished or deferred, and why

```

## Example entry

```
## 2025-11-14 — Switched package manager from pip to uv

Migrated the project tooling to uv after repeated environment reproducibility
issues with pip + venv across machines.

- Replaced requirements.txt with pyproject.toml managed by uv
- Kept requirements.txt as a lockfile export for compatibility with CI
- Decided NOT to pin transitive deps yet — too noisy, revisit if builds break
- Deferred moving to uv workspaces; overkill for now given single-package structure

```

---

<!-- CHANGES BELOW THIS LINE -->
CHANGES_EOF
}

# Sentinel string — used to detect whether the intro block is already present
SENTINEL="<!-- CHANGES BELOW THIS LINE -->"

# =============================================================================
#  HELPER: install or prepend CHANGES.md in a single repo
# =============================================================================

install_changes_md() {
    local repo_dir="$1"
    local changes_file="${repo_dir}/CHANGES.md"

    # Verify this is actually a git repo
    if [[ ! -d "${repo_dir}/.git" ]]; then
        warn "Not a git repo, skipping: ${repo_dir}"
        return 0
    fi

    if [[ ! -f "${changes_file}" ]]; then
        # Fresh install — write the full template
        changes_md_content > "${changes_file}"
        ok "Created: ${changes_file}"

    elif grep -qF "${SENTINEL}" "${changes_file}" 2>/dev/null; then
        # Intro block already present — skip
        ok "Already has intro block, skipping: ${changes_file}"
        return 0

    else
        # File exists but lacks the intro — prepend intro above existing content
        local tmp
        tmp=$(mktemp)
        {
            changes_md_content
            echo ""
            cat "${changes_file}"
        } > "${tmp}"
        mv "${tmp}" "${changes_file}"
        ok "Prepended intro block to existing: ${changes_file}"
    fi

    # Stage the file
    git -C "${repo_dir}" add CHANGES.md
    ok "Staged CHANGES.md in $(basename "${repo_dir}")"
}

# =============================================================================
#  HELPER: commit staged CHANGES.md if there is anything staged
# =============================================================================

commit_if_staged() {
    local repo_dir="$1"
    local repo_name
    repo_name=$(basename "${repo_dir}")

    # Check whether CHANGES.md is staged
    if git -C "${repo_dir}" diff --cached --name-only 2>/dev/null | grep -q "CHANGES.md"; then
        git -C "${repo_dir}" commit -m "docs: add CHANGES.md maintenance journal" \
            --no-verify 2>/dev/null \
            && ok "Committed in ${repo_name}" \
            || warn "Commit failed in ${repo_name} — commit manually"
    else
        info "Nothing to commit in ${repo_name} (already up to date)"
    fi
}

# =============================================================================
#  SECTION 1: Existing repos
# =============================================================================

section "1. Existing repos"

# Explicitly listed repos — expand paths
EXISTING_REPOS=(
    "${HOME}/claude"
    "${HOME}/scripts"
    "${HOME}/projects"
)

for repo in "${EXISTING_REPOS[@]}"; do
    if [[ -d "${repo}" ]]; then
        install_changes_md "${repo}"
        commit_if_staged "${repo}"
    else
        warn "Directory not found, skipping: ${repo}"
    fi
done

# =============================================================================
#  SECTION 2: git init template — all future repos get CHANGES.md automatically
# =============================================================================

section "2. Git init template (future repos)"

GIT_TEMPLATE_DIR="${HOME}/.config/git/template"
TEMPLATE_CHANGES="${GIT_TEMPLATE_DIR}/CHANGES.md"

mkdir -p "${GIT_TEMPLATE_DIR}"
changes_md_content > "${TEMPLATE_CHANGES}"
ok "Template written: ${TEMPLATE_CHANGES}"

# Configure git to use this template directory for all new repos
git config --global init.templateDir "${GIT_TEMPLATE_DIR}"
ok "git config --global init.templateDir set to ${GIT_TEMPLATE_DIR}"

info "All future 'git init' and 'git clone' runs will include CHANGES.md automatically."

# =============================================================================
#  SECTION 3: Summary
# =============================================================================

section "3. Summary"

echo ""
echo -e "${BOLD}Existing repos processed:${RESET}"
for repo in "${EXISTING_REPOS[@]}"; do
    if [[ -d "${repo}" ]]; then
        echo "  ${repo}"
    else
        echo "  ${repo}  (not found — skipped)"
    fi
done
echo ""
echo -e "${BOLD}Git template directory:${RESET} ${GIT_TEMPLATE_DIR}"
echo ""
echo -e "${BOLD}To add CHANGES.md to any other existing repo:${RESET}"
echo "  bash setup-changes-md.sh  (edit EXISTING_REPOS array first)"
echo "  — or manually:"
echo "  cp ${TEMPLATE_CHANGES} /path/to/repo/"
echo "  git -C /path/to/repo add CHANGES.md && git -C /path/to/repo commit -m 'docs: add CHANGES.md'"
echo ""
ok "Done."
