#!/usr/bin/env bash
# macos-files-clean.sh
# General-purpose macOS filesystem artifact cleanup tool.
# Removes all common macOS junk files and directories left behind
# when transferring files to Linux or Android devices.
#
# Usage: macos-files-clean.sh [options] [target-directory]
#
# Options:
#   -n, --dry-run    Show what would be deleted without removing anything
#   -h, --help       Show this help message

set -euo pipefail

# --- Argument parsing ---
DRY_RUN=false
TARGET=""

usage() {
    echo "Usage: macos-files-clean.sh [options] [target-directory]"
    echo ""
    echo "Options:"
    echo "  -n, --dry-run    Show what would be deleted without removing anything"
    echo "  -h, --help       Show this help message"
    echo ""
    echo "target-directory defaults to current working directory if not provided."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *) TARGET="$1"; shift ;;
    esac
done

TARGET="${TARGET:-$(pwd)}"

if [ ! -d "$TARGET" ]; then
    echo "Error: '$TARGET' is not a directory." >&2
    exit 1
fi

# --- Artifact definitions ---
declare -A FILE_PATTERNS=(
    ["._*"]="Resource forks (AppleDouble)"
    [".DS_Store"]="Finder folder settings"
    [".AppleDB"]="Apple desktop database"
    [".VolumeIcon.icns"]="Custom volume icon"
)

declare -A DIR_PATTERNS=(
    [".AppleDouble"]="Resource fork directory"
    [".Spotlight-V100"]="Spotlight search index"
    [".fseventsd"]="Filesystem event log"
    [".TemporaryItems"]="macOS temporary items"
    [".Trashes"]="macOS trash folder"
    ["__MACOSX"]="macOS zip resource fork directory"
)

# --- Scan ---
if $DRY_RUN; then
    echo "DRY RUN — no files will be deleted"
fi
echo "Scanning: $TARGET"
echo ""
printf "  %-8s %-22s %6s  %s\n" "TYPE" "PATTERN" "COUNT" "DESCRIPTION"
printf "  %-8s %-22s %6s  %s\n" "--------" "----------------------" "------" "-----------"

TOTAL=0

collect_counts() {
    local type="$1" pattern="$2" desc="$3" fd_type="$4"
    local count
    count=$(fdfind --hidden --type "$fd_type" --glob "$pattern" "$TARGET" | wc -l)
    if [ "$count" -gt 0 ]; then
        printf "  %-8s %-22s %6d  %s\n" "[$type]" "$pattern" "$count" "$desc"
        TOTAL=$((TOTAL + count))
    fi
}

for pattern in "${!FILE_PATTERNS[@]}"; do
    collect_counts "file" "$pattern" "${FILE_PATTERNS[$pattern]}" "f"
done

# Icon* handled separately (broad glob, files only)
ICON_COUNT=$(fdfind --hidden --type f --glob "Icon*" "$TARGET" | wc -l)
if [ "$ICON_COUNT" -gt 0 ]; then
    printf "  %-8s %-22s %6d  %s\n" "[file]" "Icon*" "$ICON_COUNT" "Custom folder icons"
    TOTAL=$((TOTAL + ICON_COUNT))
fi

for pattern in "${!DIR_PATTERNS[@]}"; do
    collect_counts "dir" "$pattern" "${DIR_PATTERNS[$pattern]}" "d"
done

echo ""
printf "  Total: %d item(s)\n" "$TOTAL"
echo ""

if [ "$TOTAL" -eq 0 ]; then
    echo "No macOS artifacts found. Nothing to do."
    exit 0
fi

if $DRY_RUN; then
    echo "Dry run complete. Run without --dry-run to delete."
    exit 0
fi

# --- Deletion ---
for pattern in "${!FILE_PATTERNS[@]}"; do
    fdfind --hidden --type f --glob "$pattern" "$TARGET" -x rm {}
done

fdfind --hidden --type f --glob "Icon*" "$TARGET" -x rm {}

for pattern in "${!DIR_PATTERNS[@]}"; do
    fdfind --hidden --type d --glob "$pattern" "$TARGET" | sort -r | xargs -r rm -rf
done

echo "Done. Removed $TOTAL macOS artifact(s)."
