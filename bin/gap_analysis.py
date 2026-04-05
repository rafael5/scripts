#!/usr/bin/env python3
"""
VistA corpus gap analysis.

Compares active VistA KIDS packages against markdown coverage in the corpus.

Classification source: ~/claude/skills/vista-system/vista-kids-packages.csv
  kids_scope=true  → in scope (VistA, VistA+GUI, VistA+COTS, VistA+middleware, Data patch)
  kids_scope=false → out of scope (Web client, Middleware, Enterprise, COTS, etc.)

Usage (on minty, from any directory):
    gap_analysis.py

Options:
    --inventory PATH   enriched inventory CSV (default: ~/data/vista-docs/inventory/vdl_inventory_enriched.csv)
    --markdown  PATH   markdown output dir  (default: ~/data/vista-docs/md-img)
    --kids      PATH   KIDS package list    (default: ~/claude/skills/vista-system/vista-kids-packages.csv)
    --all              show all apps including non-KIDS
"""

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path


DEFAULTS = {
    "inventory": Path.home() / "data/vista-docs/inventory/vdl_inventory_enriched.csv",
    "markdown":  Path.home() / "data/vista-docs/md-img",
    "kids":      Path.home() / "claude/skills/vista-system/vista-kids-packages.csv",
}


def load_kids_map(path: Path) -> dict[str, dict]:
    """Return {app_name_abbrev: {system_type, kids_scope, section, description}}."""
    result = {}
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            result[row["app_name_abbrev"]] = {
                "system_type":  row["system_type"],
                "kids_scope":  row["kids_scope"].strip().lower() == "true",
                "section":     row["section"],
                "description": row["description"],
            }
    return result


def load_active_apps(inventory: Path) -> dict[str, dict]:
    """Return {app_name_abbrev: {app_name_full, total_docs}} for active, non-noise rows."""
    apps: dict[str, dict] = {}
    counts: dict[str, int] = defaultdict(int)

    with open(inventory, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get("noise_type", "").strip():
                continue
            if row.get("app_status", "").strip() != "active":
                continue
            code = row.get("app_name_abbrev", "").strip()
            if not code:
                continue
            if code not in apps:
                apps[code] = {"app_name": row.get("app_name_full", "").strip()}
            counts[code] += 1

    for code in apps:
        apps[code]["total_docs"] = counts[code]
    return apps


def count_markdown(markdown_dir: Path) -> dict[str, int]:
    """Return {app_name_abbrev: .md file count} from markdown output directory."""
    if not markdown_dir.exists():
        return {}
    return {
        d.name: sum(1 for f in d.iterdir() if f.suffix == ".md")
        for d in markdown_dir.iterdir() if d.is_dir()
    }


def print_table(title: str, rows: list[dict]) -> None:
    if not rows:
        print(f"\n{title}: (none)\n")
        return

    cw_code = max(8,  max(len(r["code"])    for r in rows))
    cw_type = max(10, max(len(r["type"])    for r in rows))
    cw_name = min(38, max(len(r["name"])    for r in rows))
    cw_tot  = max(5,  max(len(str(r["total"]))    for r in rows))
    cw_ing  = max(8,  max(len(str(r["ingested"])) for r in rows))
    cw_gap  = max(3,  max(len(str(r["gap"]))      for r in rows))

    def fmt(r: dict) -> str:
        return (
            f"  {r['code']:<{cw_code}}"
            f"  {r['type']:<{cw_type}}"
            f"  {r['name']:<{cw_name}}"
            f"  {r['total']:>{cw_tot}}"
            f"  {r['ingested']:>{cw_ing}}"
            f"  {r['gap']:>{cw_gap}}"
        )

    sep = "-" * (cw_code + cw_type + cw_name + cw_tot + cw_ing + cw_gap + 14)
    header = {"code": "APP_CODE", "type": "VISTA_TYPE", "name": "APP_NAME",
              "total": "TOTAL", "ingested": "INGESTED", "gap": "GAP"}

    total_t = sum(r["total"]    for r in rows)
    total_i = sum(r["ingested"] for r in rows)
    total_g = sum(r["gap"]      for r in rows)

    print(f"\n{'='*len(sep)}")
    print(f"  {title}  ({len(rows)} apps)")
    print(f"{'='*len(sep)}")
    print(fmt(header))
    print(sep)
    for r in sorted(rows, key=lambda x: x["gap"], reverse=True):
        print(fmt(r))
    print(sep)
    print(fmt({"code": "TOTAL", "type": "", "name": "",
               "total": total_t, "ingested": total_i, "gap": total_g}))


def main() -> None:
    parser = argparse.ArgumentParser(description="VistA corpus gap analysis")
    parser.add_argument("--inventory", type=Path, default=DEFAULTS["inventory"])
    parser.add_argument("--markdown",  type=Path, default=DEFAULTS["markdown"])
    parser.add_argument("--kids",      type=Path, default=DEFAULTS["kids"])
    parser.add_argument("--all",       action="store_true",
                        help="Show all apps including non-KIDS")
    args = parser.parse_args()

    for label, path in [("inventory", args.inventory), ("kids", args.kids)]:
        if not path.exists():
            print(f"ERROR: {label} file not found: {path}", file=sys.stderr)
            sys.exit(1)

    kids_map  = load_kids_map(args.kids)
    apps      = load_active_apps(args.inventory)
    md_counts = count_markdown(args.markdown)

    kids_rows       = []
    non_kids_rows   = []
    unknown_rows    = []

    for code, info in apps.items():
        ingested = md_counts.get(code, 0)
        total    = info["total_docs"]
        gap      = max(0, total - ingested)

        if code in kids_map:
            entry = kids_map[code]
            row = {
                "code":     code,
                "type":     entry["system_type"],
                "name":     info["app_name"][:38],
                "total":    total,
                "ingested": ingested,
                "gap":      gap,
            }
            if entry["kids_scope"]:
                kids_rows.append(row)
            elif args.all:
                non_kids_rows.append(row)
        else:
            unknown_rows.append({
                "code":     code,
                "type":     "UNKNOWN",
                "name":     info["app_name"][:38],
                "total":    total,
                "ingested": ingested,
                "gap":      gap,
            })

    print_table("KIDS VistA PACKAGES — GAP ANALYSIS", kids_rows)

    if args.all:
        print_table("NON-KIDS (out of scope)", non_kids_rows)

    if unknown_rows:
        print_table("UNCLASSIFIED — not in vista-kids-packages.csv", unknown_rows)
        print("\nAdd unclassified app_codes to ~/claude/skills/vista-system/vista-kids-packages.csv")

    print("\nNOTE: TOTAL includes both PDF and DOCX pairs. True unique doc count ≈ TOTAL/2.")


if __name__ == "__main__":
    main()
