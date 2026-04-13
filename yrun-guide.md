# yrun — Guide

## Purpose

Run any YottaDB (MUMPS/M) routine from the terminal without needing to navigate
to the YottaDB project directory or manually set environment variables. A thin
wrapper that loads the YottaDB environment and passes all arguments directly to
the `ydb` binary.

## Design

The script locates the YottaDB project root by resolving its own path relative to
`scripts/ydb-env.sh` (one directory level up from `scripts/bin/`). It sources
`ydb-env.sh` which sets `$YDB` and the other required YottaDB environment
variables, then `exec`s the `ydb` binary with the provided arguments — replacing
itself in the process table rather than spawning a child shell.

This design means:
- The script works from **any directory**
- Environment setup is centralised in `ydb-env.sh` (not duplicated here)
- No leftover bash process — `exec` keeps the process tree clean
- Arguments after the routine name become `$ZCMDLINE` inside MUMPS

## Features

- Works from any directory
- No manual environment setup required
- Passes all arguments to `ydb -run` including extra args for `$ZCMDLINE`
- Aborts with usage message if called with no arguments
- `set -euo pipefail` — fails cleanly on environment errors
- `exec` replaces the shell process — clean exit

## Functions

No functions. Linear flow:

| Step | Action |
|------|--------|
| PROJ_DIR | Resolve project root from script location |
| source | Load `$PROJ_DIR/scripts/ydb-env.sh` (sets `$YDB` and YDB globals paths) |
| arg check | Print usage and exit 1 if no routine name given |
| exec | `exec "$YDB" -run "$@"` — hand off to YottaDB |

## Use

```bash
# Run a routine
yrun ^HELLOTST
yrun ^GLOBALTST

# Run with arguments (available as $ZCMDLINE in MUMPS)
yrun ^ROUTINE arg1 arg2

# Caret is optional if the routine name is unambiguous
yrun ^hello
```

## Requirements

- YottaDB installed and `ydb-env.sh` present at `<project-root>/scripts/ydb-env.sh`
- `ydb-env.sh` must export `$YDB` pointing to the `ydb` binary
- The `yrun` script must remain in `<project-root>/scripts/bin/`

## Notes

The script locates `ydb-env.sh` by resolving `"$(dirname "${BASH_SOURCE[0]}")/.."` —
this is the YottaDB project root. Moving `yrun` out of `scripts/bin/` without
adjusting the relative path will break it.
