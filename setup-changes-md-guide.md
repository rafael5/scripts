# setup-changes-md — Guide

## Purpose

Install a canonical `CHANGES.md` maintenance journal into existing git
repositories and configure a `git init` template so all future repositories
get one automatically. The journal format is designed to capture _why_ things
changed — intent, decisions, and context that commit messages alone don't record.

## Design

Three-section script:

1. **Existing repos** — iterates a hardcoded list of repo paths and installs
   `CHANGES.md` into each. Non-destructive: if the file already exists and
   contains the sentinel string `<!-- CHANGES BELOW THIS LINE -->`, it is left
   alone. If the file exists but lacks the intro block, the block is prepended
   while existing content is preserved.

2. **git init template** — writes `CHANGES.md` to `~/.config/git/template/` and
   sets `git config --global init.templateDir` to point there. All subsequent
   `git init` and `git clone` operations will include the file automatically.

3. **Summary** — lists repos processed and shows the manual-add command for repos
   not in the hardcoded list.

The canonical content lives in a single `changes_md_content()` function. Editing
that function updates what gets written to both existing repos and the template —
one source of truth.

## Features

- Idempotent: re-running is safe; existing intros are never duplicated
- Non-destructive prepend: existing content is preserved below the intro block
- Auto-stages and commits `CHANGES.md` in each repo
- Sets `git init` template for all future repos
- Coloured output with `[INFO]`, `[OK]`, `[WARN]` labels
- Handles missing or non-git directories gracefully

## Functions

| Function | Description |
|---|---|
| `changes_md_content` | Emits the canonical `CHANGES.md` content via heredoc |
| `install_changes_md repo_dir` | Creates or prepends `CHANGES.md` in one repo and stages it |
| `commit_if_staged repo_dir` | Commits staged `CHANGES.md` if present; warns on failure |
| `info/ok/warn/section` | Coloured log output helpers |

## Use

```bash
# Install into the default repo list
setup-changes-md.sh
```

Default repos processed: `~/claude`, `~/scripts`, `~/projects`

To add more repos, edit the `EXISTING_REPOS` array at the top of section 1, then re-run.

To add `CHANGES.md` to any other repo manually:
```bash
cp ~/.config/git/template/CHANGES.md /path/to/repo/
git -C /path/to/repo add CHANGES.md
git -C /path/to/repo commit -m "docs: add CHANGES.md maintenance journal"
```

## Sentinel

The sentinel comment `<!-- CHANGES BELOW THIS LINE -->` marks the boundary between
the intro block and user-written entries. The script checks for this string to
determine whether the intro is already present. Do not remove this line from
`CHANGES.md` or the script will prepend the intro again on the next run.
