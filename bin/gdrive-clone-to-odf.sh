#!/usr/bin/env bash
# =============================================================================
#  gdrive-clone-to-odf.sh
#  Version: 1.0.0
#  Target:  Linux with rclone configured for Google Drive
#
#  Purpose
#  Clone an entire Google Drive to local storage and convert all documents to
#  Open Document Format (ODF). Google-native files are exported server-side
#  during sync; MS Office files are converted locally via LibreOffice headless.
#
#  Design
#  Two-phase pipeline: (1) rclone copy with --drive-export-formats odt,ods,odp
#  for server-side Google export; (2) find + libreoffice --headless --convert-to
#  for any .doc/.docx/.xls/.xlsx/.ppt/.pptx files in the clone. All output goes
#  to ~/gdrive-clone/. Activity is logged to ~/gdrive-clone/clone_odf.log.
#
#  Features
#  - Server-side Google Docs/Sheets/Slides export (no double conversion)
#  - Batch LibreOffice conversion: doc/docx→odt, xls/xlsx→ods, ppt/pptx→odp
#  - Preserves directory structure and empty source dirs
#  - Running log via tee to clone_odf.log
#
#  Functions
#  convert_office file    Dispatch one MS Office file to libreoffice --headless
#
#  Use
#  gdrive-clone-to-odf.sh
#  Requires: rclone configured with a remote named "gdrive:", libreoffice
# =============================================================================

set -euo pipefail

# CONFIGURATION
RCLONE_REMOTE="gdrive:"
LOCAL_DIR="$HOME/gdrive-clone"
LOG_FILE="$LOCAL_DIR/clone_odf.log"

# Ensure output folder exists
mkdir -p "$LOCAL_DIR"

echo "Starting Google Drive clone and conversion..." | tee -a "$LOG_FILE"

# STEP 1: Clone Google Drive with Google-native export to ODF
echo "Step 1: Copying Google Drive with Google-native export (odt, ods, odp)..." | tee -a "$LOG_FILE"
rclone copy "$RCLONE_REMOTE" "$LOCAL_DIR" \
    --progress \
    --create-empty-src-dirs \
    --drive-export-formats odt,ods,odp \
    2>&1 | tee -a "$LOG_FILE"

# STEP 2: Convert Microsoft Office files to ODF
echo "Step 2: Converting Microsoft Office files to ODF formats..." | tee -a "$LOG_FILE"

# Function to convert with libreoffice
convert_office() {
    local file="$1"
    local dir
    dir=$(dirname "$file")
    case "$file" in
        *.doc|*.docx)
            libreoffice --headless --convert-to odt --outdir "$dir" "$file"
            ;;
        *.xls|*.xlsx)
            libreoffice --headless --convert-to ods --outdir "$dir" "$file"
            ;;
        *.ppt|*.pptx)
            libreoffice --headless --convert-to odp --outdir "$dir" "$file"
            ;;
    esac
}

# Find and convert MS Office files
find "$LOCAL_DIR" -type f \( -iname "*.doc" -o -iname "*.docx" -o -iname "*.xls" -o -iname "*.xlsx" -o -iname "*.ppt" -o -iname "*.pptx" \) | while read -r file; do
    echo "Converting: $file" | tee -a "$LOG_FILE"
    convert_office "$file"
done

echo "All conversions completed. Local clone is in: $LOCAL_DIR" | tee -a "$LOG_FILE"
