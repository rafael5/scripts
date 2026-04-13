# gdrive-clone-to-odf — Guide

## Purpose

Clone an entire Google Drive to local storage and convert all documents to
Open Document Format (ODF). Google-native files (Docs, Sheets, Slides) are
exported during the sync; Microsoft Office files found in the clone are converted
via LibreOffice afterwards. The result is a local archive in fully open,
vendor-neutral formats.

## Design

Two-phase pipeline:

1. **rclone sync phase** — pulls Google Drive to `~/gdrive-clone/` with the
   `--drive-export-formats odt,ods,odp` flag, which instructs rclone to request
   Google's server-side export for Google Docs/Sheets/Slides on download. No
   local conversion is needed for Google-native files.

2. **LibreOffice conversion phase** — walks the cloned tree with `find` and calls
   `libreoffice --headless --convert-to` for each `.doc/.docx`, `.xls/.xlsx`, and
   `.ppt/.pptx` file found. Converts in-place (output dir = same dir as source).

All output goes to `~/gdrive-clone/` and a running log is written to
`~/gdrive-clone/clone_odf.log`.

## Features

- Clones entire Google Drive with progress display
- Native server-side Google export (no quality loss from double conversion)
- Batch converts all MS Office formats: Word → ODT, Excel → ODS, PowerPoint → ODP
- Preserves original directory structure
- Logs all activity to `clone_odf.log` with `tee`
- `--create-empty-src-dirs` preserves empty Google Drive folders

## Functions

| Function | Description |
|---|---|
| `convert_office file` | Dispatches a single file to the correct LibreOffice headless conversion based on extension |

Main flow (inline, not in a function):

| Step | Command | Description |
|------|---------|-------------|
| 1 | `rclone copy gdrive: ~/gdrive-clone` | Sync Google Drive with ODF export |
| 2 | `find … -type f \( -iname "*.doc*" … \)` | Locate all MS Office files in clone |
| 3 | `convert_office "$file"` | Convert each file with LibreOffice headless |

## Use

```bash
# Prerequisites: configure rclone with a Google Drive remote named "gdrive:"
rclone config   # one-time setup — follow interactive wizard

# Run the clone + conversion
gdrive-clone-to-odf.sh
```

Output is written to `~/gdrive-clone/`. The log is at `~/gdrive-clone/clone_odf.log`.

## Configuration

Edit the top of the script to change defaults:

| Variable | Default | Description |
|---|---|---|
| `RCLONE_REMOTE` | `gdrive:` | rclone remote name for Google Drive |
| `LOCAL_DIR` | `~/gdrive-clone` | Local destination directory |
| `LOG_FILE` | `$LOCAL_DIR/clone_odf.log` | Log file path |

## Dependencies

| Tool | Install |
|---|---|
| `rclone` | `sudo apt install rclone` + `rclone config` |
| `libreoffice` | `sudo apt install libreoffice` |
