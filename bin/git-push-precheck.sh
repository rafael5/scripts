#!/bin/bash
###############################################################################
# git-push-precheck.sh
# Version: 1.1
# Date: 2026-03-19
#
# Pre-Push Checklist Script for Git Repositories
#
# Description:
#   This script performs a comprehensive pre-push checklist to ensure your
#   repository is clean, synchronized, and ready to push. It detects potential
#   issues that could cause failed pushes, large file mishandling, or unwanted
#   commits to the remote repository.
#
# Features:
#   0️⃣ Detects repository authentication type (SSH vs HTTPS)
#   1️⃣ Shows current branch
#   2️⃣ Checks if local branch is ahead/behind remote (fast or full fetch mode)
#   3️⃣ Detects uncommitted changes in working directory and staging area
#   4️⃣ Scans for common dotfiles and optionally removes them (.DS_Store, .venv)
#   5️⃣ Detects large files (>50MB), checks Git LFS tracking, and prints details
#   6️⃣ Provides interactive prompts for cleanup and inspection
#
# Usage:
#   chmod +x git-push-precheck.sh
#   ./git-push-precheck.sh
#
# Modes:
#   FAST_MODE=true   → No network delay, uses ls-remote for branch hash check
#   FAST_MODE=false  → Full accuracy, fetches remote branch before comparison
###############################################################################

FAST_MODE=true   # <-- TOGGLE THIS

# Colors
BLUE_BOLD="\033[1;34m"
RESET="\033[0m"

echo -e "=== Pre-Push Checklist ==="

# 0️⃣ Repository Authentication Check
echo -e "${BLUE_BOLD}Checking repository authentication type...${RESET}"
REMOTE_URL=$(git remote get-url origin)
echo "  Remote URL: $REMOTE_URL"

if [[ $REMOTE_URL == git@github.com* ]]; then
    echo "  ✅ Repository is using SSH"
elif [[ $REMOTE_URL == https://* ]]; then
    echo "  ⚠️ Repository uses HTTPS (PAT required)"
    echo "     Run ./git-ssh-auth-setup.sh to convert to SSH"
else
    echo "  ⚠️ Unknown remote type"
fi

# 1️⃣ Current Branch
echo -e "${BLUE_BOLD}Current branch...${RESET}"
CURRENT_BRANCH=$(git branch --show-current)
echo "  Branch: $CURRENT_BRANCH"

# 2️⃣ Branch Sync Check
echo -e "${BLUE_BOLD}Checking if local branch is behind origin...${RESET}"
LOCAL_HASH=$(git rev-parse "$CURRENT_BRANCH")

if [ "$FAST_MODE" = true ]; then
    REMOTE_HASH=$(git ls-remote --heads origin "$CURRENT_BRANCH" | awk '{print $1}')
    if [ -z "$REMOTE_HASH" ]; then
        echo "  ⚠️ Could not determine remote branch (offline or network issue)"
    elif [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        echo "  ⚠️ Local branch differs from remote (ahead or behind)"
    else
        echo "  ✅ Local branch matches remote"
    fi
else
    GIT_LFS_SKIP_SMUDGE=1 git fetch --quiet origin
    REMOTE_HASH=$(git rev-parse "origin/$CURRENT_BRANCH")
    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        echo "  ⚠️ Local branch is behind remote"
    else
        echo "  ✅ Local branch is up-to-date"
    fi
fi

# 3️⃣ Uncommitted Changes Check
echo -e "${BLUE_BOLD}Checking for uncommitted changes...${RESET}"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "  ⚠️ You have uncommitted changes"
else
    echo "  ✅ Working directory clean"
fi

# 4️⃣ Dotfiles Scan
echo -e "${BLUE_BOLD}Scanning for dotfiles...${RESET}"
DOTFILES=("*.DS_Store" ".venv" "env" "venv")
for pattern in "${DOTFILES[@]}"; do
    MATCHES=$(find . -name "$pattern")
    if [ -n "$MATCHES" ]; then
        echo "$MATCHES"
    fi
done

# 4a️⃣ Remove .DS_Store Option
DS_STORE_FILES=$(find . -name ".DS_Store")
if [ -n "$DS_STORE_FILES" ]; then
    echo "Remove all .DS_Store files? (y/n)"
    read -r RESPONSE
    if [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
        echo "$DS_STORE_FILES" | xargs rm -f
        echo "Removed"
    fi
fi

# 5️⃣ Large File + LFS Check
echo -e "${BLUE_BOLD}Checking for large files and Git LFS tracking...${RESET}"

EXCLUDE_DIRS=( ".git" ".venv" "env" "venv" )
PRUNE_ARGS=()
for dir in "${EXCLUDE_DIRS[@]}"; do
    PRUNE_ARGS+=( -path "./$dir" -prune -o )
done

# Find files larger than 50MB
LARGE_FILES_RAW=$(find . "${PRUNE_ARGS[@]}" -type f -size +50M -print)
FILE_COUNT=$(echo "$LARGE_FILES_RAW" | grep -cve '^\s*$')

if [ "$FILE_COUNT" -gt 0 ]; then
    echo "  ⚠️ $FILE_COUNT large file(s) detected"

    UNTRACKED=false
    TABLE=""

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        SIZE=$(du -h -- "$file" | cut -f1)

        if git lfs track | grep -q "$(basename "$file")"; then
            STATUS="LFS ✅"
        else
            STATUS="LFS ❌"
            UNTRACKED=true
        fi

        TABLE+="$file | $SIZE | $STATUS"$'\n'
    done <<< "$LARGE_FILES_RAW"

    echo "Print list? (y/n)"
    read -r RESP
    if [[ "$RESP" =~ ^[Yy]$ ]]; then
        echo "Path | Size | LFS"
        echo "$TABLE"
    fi

    if [ "$UNTRACKED" = true ]; then
        echo ""
        echo "⚠️ WARNING: Untracked large files detected"
        echo "DO NOT PUSH until tracked with Git LFS"
        echo ""
        echo "Steps:"
        echo "  git lfs track \"<file>\""
        echo "  git add .gitattributes"
        echo "  git add <file>"
        echo "  git commit -m \"Track large files\""
        echo "  git push"
        echo ""
        echo "If already committed incorrectly:"
        echo "  Use: git filter-repo or BFG"
    fi
else
    echo "  ✅ No large files"
fi

echo -e "${BLUE_BOLD}Checklist complete${RESET}"
