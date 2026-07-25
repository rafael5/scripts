# Project bootstrap & status — guide

How to start a new personal project under `~/projects/` and how to get a
one-screen view of them all. The three scripts described here live in `bin/`
and are on `$PATH`.

> Salvaged 2026-07-25 from the retired `~/claude/GUIDE.md`, which was the only
> place these were documented. Conventions + shell setup:
> [`machine-setup.md`](machine-setup.md).

## Scope — personal projects only

This covers `~/projects/` work (the legacy Python→Go line). **`~/vista-forge/`
does not use these templates** — the org is deliberately self-contained and
scaffolds from its own in-org `go-cli-template`, or `v new` for a `v` domain.
Do not copy a template from here into the org: this one ships a GitHub Actions
workflow, which vista-forge bans under its forge-portable rule.

## Starting a new project

```bash
new-py-project myapp     # Python — full bootstrap
new-go-project mytool    # Go    — full bootstrap
```

Each wraps the whole dance: copy the template from `~/scripts/templates/`,
rename the package throughout, `git init`, add the
`git@github.com:rafael5/<name>.git` remote, create the per-project auto-memory
directory, and run `make install`.

Useful flags:

| Flag | Effect |
|---|---|
| `--no-install` | skip `make install` |
| `--no-remote` | skip adding the GitHub remote |
| `--data` | Go only — create `~/data/<name>/{input,output,db}` |
| `--no-data` | Python only — opt out (Python creates it by default) |

If the script doesn't fit, read it — it is the recipe, and it is the only copy
that cannot go stale.

## The templates

`templates/{python,go,node}` — TDD scaffolds. **Never hand-craft a project
layout**; copy one of these. Each ships its own `CLAUDE.md` and
`<lang>-dev-guide.md` documenting its toolchain, and they share one shape: a
language-version pin, a direnv `.envrc`, a `make check` full gate, pre-commit
hooks, and TDD.

`install-go.sh` in `bin/` installs the Go toolchain itself and prints the
manual `cp -r` recipe for the Go template.

## Cross-project status

```bash
claude-status            # plain-text table; read-only, no network
claude-status --fetch    # git fetch first, so ahead/behind is fresh
claude-status --write    # also write the markdown table to a file
```

Shows branch, last commit, dirty-file count, and ahead/behind vs origin for
every active project, so a session can start with one command instead of
opening several `CLAUDE.md` files.

## Per-project memory

Each project's auto-memory is a **real directory** at
`~/.claude/projects/<path-hash>/memory/`, written by the harness. There are no
symlinks and no shared store — an org or project `CLAUDE.md` may redirect
memory in-org instead (vista-forge does exactly that, committing memory beside
the code it describes).

> Until 2026-07-25 the bootstrap scripts symlinked that path to a shared
> `~/claude/memory`. That was the older model and had already been retired in
> `~/.claude/CLAUDE.md`; the scripts now create the real directory.

## Global Claude instructions

`~/.claude/CLAUDE.md` — edit it directly. It is the one and only global
instruction file: no symlink, no second copy, and not version-controlled here.

> Until 2026-07-21 it was *documented* as a symlink to a `CLAUDE.global.md` in
> the old workspace repo. It never was — the two had drifted 238 lines apart,
> so every edit made per that instruction silently did nothing. The stale copy
> was deleted. Worth remembering before introducing any "second home" for a
> config file: an unverified link is worse than no link.
