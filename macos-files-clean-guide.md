# macos-files-clean — Guide

## Purpose

Remove macOS filesystem artifacts from any directory tree. These files are created
automatically by macOS Finder and the HFS+/APFS filesystem when folders or volumes
are accessed on a Mac. They serve no purpose on Linux or Android and create clutter
when files are transferred between platforms.

## Design

Two-phase approach:
1. **Scan phase** — count matching items per pattern and print a summary table
   before deleting anything. In dry-run mode (`-n`), stop here.
2. **Delete phase** — remove all matched items using `fdfind` with `-x rm` for
   files and `xargs rm -rf` for directories. Directories are sorted in reverse
   order before deletion to ensure children are removed before parents.

Uses `fdfind` (Ubuntu/Debian package name for `fd`) rather than `find` for
cleaner glob matching and hidden-file support (`--hidden` flag).

Artifact definitions are stored in two bash associative arrays (`FILE_PATTERNS`
and `DIR_PATTERNS`) mapping glob pattern → human description. Adding a new
pattern requires a one-line edit.

## Features

- Dry-run mode (`-n, --dry-run`) — lists what would be removed, deletes nothing
- Scans both files and directories with distinct pattern sets
- Prints a formatted count table before any deletion
- Accepts a target directory argument; defaults to `$PWD`
- Exits cleanly with a message if no artifacts are found
- `set -euo pipefail` — aborts on any unexpected error

## Artifact Types Cleaned

| Type | Pattern | Description |
|------|---------|-------------|
| file | `._*` | Resource forks (AppleDouble metadata) |
| file | `.DS_Store` | Finder folder view settings |
| file | `.AppleDB` | Apple desktop database |
| file | `.VolumeIcon.icns` | Custom volume icon |
| file | `Icon*` | Custom folder icons |
| dir | `.AppleDouble` | Resource fork directory |
| dir | `.Spotlight-V100` | Spotlight search index |
| dir | `.fseventsd` | Filesystem event log |
| dir | `.TemporaryItems` | macOS temporary items |
| dir | `.Trashes` | macOS trash folder |
| dir | `__MACOSX` | Resource fork directory in zip archives |

## Functions

| Function | Description |
|---|---|
| `usage` | Print help text and exit |
| `collect_counts type pattern desc fd_type` | Count matching items for one pattern and add to the summary table |

## Use

```bash
# Clean the current directory (interactive — asks before deleting)
macos-files-clean.sh

# Clean a specific directory
macos-files-clean.sh ~/Downloads

# Preview what would be removed without deleting
macos-files-clean.sh --dry-run ~/Downloads
macos-files-clean.sh -n /media/usb-drive

# Show help
macos-files-clean.sh --help
```

## Dependencies

| Tool | Install |
|---|---|
| `fdfind` | `sudo apt install fd-find` |
