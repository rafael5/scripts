# gap_analysis — Guide

## Purpose

Measure how much of the VistA Document Library (VDL) corpus has been ingested
into the local markdown corpus. Compares the number of active documents in the
VDL inventory against the number of converted markdown files on disk, per VistA
application package, and reports the gap.

Designed to answer: "which KIDS packages still have unprocessed documents?"

## Design

Three data sources are joined:

1. **Inventory CSV** (`vdl_inventory_enriched.csv`) — the master list of all VDL
   documents with their application code, status, and noise classification.
2. **KIDS package list** (`vista-kids-packages.csv`) — maps application codes to
   VistA system type, scope (in/out of KIDS target), and description.
3. **Markdown output directory** (`md-img/`) — the filesystem state of already-
   converted documents, counted per application subdirectory.

The script counts documents per `app_name_abbrev` in the inventory (excluding
noise rows and inactive records), counts `.md` files per subdirectory in the
markdown tree, and reports `gap = total_docs - ingested` for each app.

Output is sorted by gap descending so the highest-priority packages appear first.

## Features

- Three output tables: KIDS in-scope packages, non-KIDS (with `--all`), unclassified
- Gap calculation per application code
- Skips noise rows and inactive applications from the inventory
- Configurable paths via CLI arguments (all have sensible defaults)
- `--all` flag shows out-of-scope packages for completeness
- Flags unclassified codes not present in the KIDS package list
- Standard library only — no external dependencies

## Functions

| Function | Description |
|---|---|
| `load_kids_map(path)` | Loads KIDS package CSV into `{abbrev: metadata}` dict |
| `load_active_apps(inventory)` | Loads active, non-noise docs from inventory CSV into `{abbrev: {name, total_docs}}` |
| `count_markdown(markdown_dir)` | Counts `.md` files per subdirectory in the markdown output tree |
| `print_table(title, rows)` | Formats and prints one gap analysis table with auto-sized columns and totals |
| `main()` | Parses args, joins the three data sources, routes to `print_table` |

## Use

```bash
# Run with defaults (from any directory on minty)
gap_analysis.py

# Show all apps including non-KIDS out-of-scope packages
gap_analysis.py --all

# Override paths
gap_analysis.py \
  --inventory ~/data/vista-docs/inventory/vdl_inventory_enriched.csv \
  --markdown  ~/data/vista-docs/md-img \
  --kids      ~/.claude/skills/vista-system/vista-kids-packages.csv
```

## Output Format

```
=====================================================================
  KIDS VistA PACKAGES — GAP ANALYSIS  (N apps)
=====================================================================
  APP_CODE  VISTA_TYPE  APP_NAME                    TOTAL  INGESTED  GAP
  --------  ----------  --------------------------  -----  --------  ---
  FH        VistA       Dietetics                      42         0   42
  ...
  TOTAL                                              2909       412 2497
```

A note at the bottom reminds that TOTAL counts both PDF and DOCX pairs, so
true unique document count ≈ TOTAL/2.

## Default Paths

| Argument | Default |
|---|---|
| `--inventory` | `~/data/vista-docs/inventory/vdl_inventory_enriched.csv` |
| `--markdown` | `~/data/vista-docs/md-img` |
| `--kids` | `~/.claude/skills/vista-system/vista-kids-packages.csv` |

## Dependencies

Python 3.9+ with standard library only (`argparse`, `csv`, `pathlib`,
`collections.defaultdict`).
