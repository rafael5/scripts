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

## Serving web pages (Tailscale)

Several apps on this box serve a web UI — vdb-explorer's published site, the
CPRS Configuration Explorer, and more to come. One model, four rules, adopted
2026-08-29:

1. **Bind `127.0.0.1` only.** Tailscale is the sole door, so firewall rules,
   LAN exposure and port scans stop being part of the threat model. An app that
   binds `0.0.0.0` is a defect, not a shortcut.
2. **One systemd *user* service per app**, the unit committed in that app's own
   repo and installed by symlink into `~/.config/systemd/user/`. Nothing needs
   root. Lingering is on (`loginctl enable-linger rafael`) or services die at
   logout. Copy the hardening block from an existing unit — `ProtectSystem=strict`,
   `ProtectHome=read-only`, `PrivateTmp=true`, `NoNewPrivileges=true`,
   `Restart=on-failure`. **Never a background shell job for something that
   should stay up**: it dies with the terminal and nothing restarts it. A
   short-lived *dev* server on loopback is fine as a shell job — it is not
   mounted, and it belongs to whoever started it, so check whose it is
   (`/proc/<pid>/cmdline`, walk the parents) before killing a port.
3. **One tailnet HTTPS host, one path per app** —
   `tailscale serve --bg --https=443 --set-path /<app> http://127.0.0.1:<port>`.
   Then **`tailscale serve status` is the complete inventory of what is
   reachable**, in one screen. That auditability is the point. An app that
   cannot live under a path prefix (hard-coded absolute asset paths) gets its
   own `--https=` port: the exception, not the rule.
4. **Funnel off.** Public is a separate, deliberate decision, and it publishes a
   *copied, reviewed* directory — never a symlink into a live working tree,
   where anything later written into the repo is served to the internet.

**Gotcha, measured:** `tailscale funnel --https=443 off` removes the **entire**
443 mapping, not just its public flag. Every mount on that port must be re-added
afterwards — check `tailscale serve status` immediately, not later.

**Current state** (2026-08-29):

| app | port | URL | service |
|---|---|---|---|
| vdb-explorer published site | 8138 | `https://minty.warg-torino.ts.net/` (`/vdb-explorer/`) | `vdb-explorer.service` |
| CPRS Configuration Explorer | 8765 | `https://minty.warg-torino.ts.net/cprs-configuration` | `cprs-config-explorer.service` |

Retired the same day: a manually-started vdb-explorer dev server on 8137
(duplicated the published site) and `v-rpc-relay.service`, which had restarted
34,595 times against a binary in the deleted `~/vista-cloud-dev` and would have
bound `0.0.0.0:19431` if it ever started. Its text is kept in
`~/data/retired-units/`. **A unit that cannot start is not harmless** — it is a
restart loop nobody reads and, in that case, a rule-1 violation waiting to run.

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
