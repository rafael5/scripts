#!/usr/bin/env bash
# gdrive_clone_to_odf.sh
# Clone Google Drive and convert all documents (Google & MS Office) to ODF formats

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
