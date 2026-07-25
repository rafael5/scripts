# Machine setup & conventions — minty

Shell wiring, the standing conventions, and the backup strategy for this box.

> Salvaged 2026-07-25 from `FILESYSTEM.md`, which was retired for being an
> unmaintained snapshot: no generator, no checker, and measurably ~70% accurate
> (its project table listed a repo that no longer existed and missed one that
> did). These three sections were the only content in it that was **rules
> rather than inventory** — rules drift far slower than lists, and nothing else
> holds them. The inventory it carried is available live from `claude-status`
> and `projects-index`; the rest was already in `~/.claude/CLAUDE.md` or in
> `project-bootstrap-guide.md`.
>
> Keep this file to conventions. **Do not add an inventory of projects,
> directories or skills** — that is exactly what rotted last time.

## Shell setup

Add to `~/.bashrc`:

```bash
# Shared scripts on PATH
export PATH="$HOME/scripts/bin:$PATH"

# direnv hook (auto-activates .venv on cd into a project)
eval "$(direnv hook bash)"

# uv (Python package manager)
export PATH="$HOME/.local/bin:$PATH"
```

## Conventions

| Convention | Rule |
|---|---|
| One venv per project | Always `~/projects/myapp/.venv/`, never shared |
| Data outside the repo | Always `~/data/myapp/`, never inside `~/projects/` |
| Shared bash scripts | Add to `~/scripts/bin/`, callable by name from anywhere |
| New personal project | Always copy from `~/scripts/templates/{python,go,node}/`; never hand-craft a layout |
| New vista-forge repo | **Not** from these templates — the org is self-contained (`go-cli-template`, or `v new` for a `v` domain) |
| Git remotes | Personal repos push to `git@github.com:rafael5/`; org repos to `vista-forge`. (`VistA-Copilot` was retired 2026-07-05; `m-dev-tools` is winding down) |
| Secrets | Always in `~/projects/myapp/.env` or `~/data/<org>/auth.env`, never committed |
| Archive | `~/projects/archive/` — read-only; Claude ignores it unless explicitly asked. Index in its `README.md` |
| Persistent memory | Global prefs in `~/.claude/CLAUDE.md`; per-project in `~/.claude/projects/<hash>/memory/` (a real dir, no symlinks); org repos may redirect in-org. The legacy shared store was retired 2026-07-25 |
| CHANGES.md | Decisions and intent journal — *why*, not *what*. Distinct from a CHANGELOG (release notes); never conflate the two |

## Backup strategy

| What | Where | Strategy |
|---|---|---|
| Code | `~/projects/` (active), `~/scripts/`, `~/vista-forge/` | Git push to GitHub |
| Data | `~/data/` | rsync to external drive or NAS |
| Config | `~/.bashrc`, `~/.ssh/`, `~/.claude/` | rsync to external drive |
| Archive | `~/projects/archive/` | rsync (repos keep remotes but are frozen — no further pushes) |

> **Known gap:** `~/.claude/` is not version-controlled — no remote, no history,
> no gate. Its curated part (`CLAUDE.md`, `skills/`, `agents/`, `commands/`,
> `settings.json`, `statusline-command.sh` — under 1 MB, verified secret-free)
> is worth backing up; the rest is 1.1 GB of transcripts plus
> `.credentials.json` and must never be copied into a repo.
