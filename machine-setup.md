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
| Persistent memory | Global prefs in `~/.claude/CLAUDE.md`; per-project in `~/.claude/projects/<hash>/memory/` — a real dir only where nothing redirects; for every repo that does (40 of 55 as of 2026-08-31) it is a **symlink** into that repo's `docs/memory/`. The legacy shared store was retired 2026-07-25 |
| CHANGES.md | Decisions and intent journal — *why*, not *what*. Distinct from a CHANGELOG (release notes); never conflate the two |

## Serving web pages (Tailscale)

Several apps on this box serve a web UI — vdb-explorer's published site, the
CPRS Configuration Explorer, and more to come. One model, four rules, adopted
2026-08-29:

1. **Bind `127.0.0.1` only.** Tailscale is the sole door, so firewall rules,
   LAN exposure and port scans stop being part of the threat model. An app that
   binds `0.0.0.0` is a defect, not a shortcut — with one named exception below.
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

**Named exception to rule 1 — a VM guest cannot reach loopback.**
`v rpc-debug relay` binds `0.0.0.0:19431` *on purpose*, and that bind is the
whole point of the tool: CPRS runs in a VirtualBox VM, the vehu container
publishes the broker as `127.0.0.1:9430` (`HostIp=127.0.0.1`), and a
loopback-bound host port is unreachable from a guest — which arrives via the
VirtualBox NAT alias `10.0.2.2`. It replaced ad-hoc `socat`. Conditions on the
exception:

- **The tool owns the service**, not a hand-written unit:
  `v rpc-debug relay --install` / `--uninstall`, and `--status` to ask what is
  actually installed and listening.
- **It forwards to a loopback port on this box**, nothing further, and it is
  scoped to the CPRS-in-a-VM workflow — **uninstall it when that work stops.**
- It is a TCP forwarder for a desktop client, never a way to publish a web UI.
  A web UI still follows rules 1–4.

Design, and the six-hop failure chain it was built to make visible (every hop
failed with the same opaque `WSAECONNREFUSED`): vista-forge
`v-rpc-debug/docs/proposals/v-rpc-network-doctor.md`, 2026-06-27.

**Gotcha, measured:** `tailscale funnel --https=443 off` removes the **entire**
443 mapping, not just its public flag. Every mount on that port must be re-added
afterwards — check `tailscale serve status` immediately, not later.

**Current state** (2026-08-29):

| app | port | URL | service |
|---|---|---|---|
| vdb-explorer published site | 8138 | `https://minty.warg-torino.ts.net/` (`/vdb-explorer/`) | `vdb-explorer.service` |
| CPRS Configuration Explorer | 8765 | `https://minty.warg-torino.ts.net/cprs-configuration` | `cprs-config-explorer.service` |

Retired the same day: a manually-started vdb-explorer dev server on 8137
(it duplicated the published site) and `v-rpc-relay.service`. The unit's text is
kept in `~/data/retired-units/`; the *capability* was not retired — reinstall it
with `v rpc-debug relay --install`, per the exception above.

**Why that unit was dead, and the lesson: a unit outlives the workspace it names.**
Its `ExecStart` pointed into `~/vista-cloud-dev`, the org's former name, deleted
when the repos moved to `~/vista-forge`. It had been failing ever since — the
oldest surviving journal entry, 2026-08-01, already reads *"restart counter is at
108,898"*, and the journal has rotated since. A unit that cannot start is not
harmless: it is a restart loop nobody reads, and its failure is silent precisely
because `Restart=always` makes failure look like activity. **Prefer a tool that
installs its own service** — it can be asked `--status`, and it recreates the
unit against today's path instead of a remembered one.

## Backup strategy

| What | Where | Strategy |
|---|---|---|
| Code | `~/projects/` (active), `~/scripts/`, `~/vista-forge/` | Git push to GitHub |
| Data | `~/data/` | rsync to external drive or NAS |
| Config | `~/.bashrc`, `~/.ssh/`, `~/.claude/` | rsync to external drive |
| Archive | `~/projects/archive/` | rsync (repos keep remotes but are frozen — no further pushes) |

> **`~/.claude/` — what is and is not covered** (re-measured 2026-08-31):
> `minty-backup` borgs all of `/` nightly with no `~/.claude` exclusion, so it
> **is** versioned there, with history and 7d/4w/6m retention. Two gaps remain,
> and neither is "no backup":
>
> 1. **No off-site copy.** The cloud phase is disabled (`CLOUD_REMOTE=""`), so
>    every copy lives on this box or on `/mnt/minty-backup`.
> 2. **The curated part is not self-contained.** `CLAUDE.md`, `skills/`,
>    `agents/`, `commands/`, `settings.json`, `statusline-command.sh` come to
>    280 KB and are verified secret-free — but `skills/` (14 of 21) and
>    `projects/*/memory/` (40 of 55) are **symlinks** into `~/vista-forge` and
>    `~/projects`. A plain `rsync` or `git clone` restores dangling links; a
>    full-`/` borg restore is fine. For a config-only copy use
>    **`claude-config-export <dir>`**, which resolves every link and FAILS on a
>    dangling link or an empty directory rather than producing a quietly
>    incomplete tree. (`--check <dir>` verifies an existing export.)
>
> The other 96 % of the 927 MB is ephemeral — `projects/` transcripts (773 MB,
> aged out at the 30-day `cleanupPeriodDays` default) and `file-history/`
> (122 MB). `.credentials.json` must never be copied into a repo.

## Node version management — machine-wide (2026-08-31)

**One Node, one major, declared once.** There is exactly one `node` on this box:
nvm-managed, no apt `nodejs` (purged 2026-08-31 — 152 packages; apt Node is
unpinnable and shadowed nvm at `/usr/bin/node` v18 for months).

### The contract

| Layer | Rule |
|---|---|
| `~/scripts/node-policy.env` | Declares `NODE_MAJOR`. The only place a major is written. |
| every package | `.node-version` holds the **major only** (`24`), so patch/minor float |
| every package | `engines.node` is exactly `">=$NODE_MAJOR"` |
| every package | local `.npmrc` with `engine-strict=true` — npm does **not** read a parent's `.npmrc`, so this cannot be inherited |
| every package | `.envrc` with `use nvm` (this one *may* be inherited — direnv walks up) |
| every gate | a `node-pin-check` target, first prerequisite of `check`/`gate` |
| anywhere | **never** an absolute `~/.nvm/versions/node/vX.Y.Z` path |

That last rule has teeth: a hardcoded v22 path in `~/.claude.json` broke the
Playwright MCP server the moment that version was uninstalled. Absolute version
paths are the one thing that turns a routine bump into an outage.

### Commands

    node-doctor              # verify the whole contract; exit 1 on drift
    node-doctor --self-test  # plant each violation, prove every check can RED
    node-doctor --list       # every discovered package (node-bump shares this)
    node-bump 26             # REHEARSE: install 26, clean `npm ci` + real gate
                             #   on every package. Changes no pins, no default.
    node-bump 26 --apply     # switch — only after a green rehearsal
    node-bump --retire 24    # uninstall old major; refuses while referenced

### Why rehearse

A green `make check` on stale `node_modules` is a FALSE pass — the real test of
a bump is a clean `npm ci` (native rebuild) under the new Node, then the gate.
`node-bump` does exactly that for every package *before* touching a single pin,
so a broken repo is discovered while the old major is still the default.

### Discovery, not a registry

`node-doctor` finds packages by `find` under `NODE_SCAN_ROOTS`. There is no
checked-in inventory to drift — a new repo is covered the day it appears. It
found two packages a manual survey had missed.

Repos whose git remote is not ours are reported as `FOREIGN` and never failed:
fixing them would dirty someone else's checkout and conflict on every pull.
`NODE_ENFORCE_ANYWAY` overrides that for a named path by explicit decision
(`~/gzb/b4p-vscode` — a consumer of b4p doc artifacts, not b4p product source).

### Trigger

`node-doctor-cron`, Tuesdays 04:20, via crontab. Silent when clean; ntfy on
drift, reusing the `minty-backup-watch` topic-resolution pattern. Offline —
no network at check time. Log: `~/data/node-doctor/sweep.log`.

### Lifecycle

`node-policy.env` records `NODE_NEXT_MAJOR=26` and its Active-LTS date
(2026-10-27). `node-doctor` reds once that date passes and `NODE_MAJOR` has not
moved, so the bump is scheduled by the checker rather than remembered.


## De-GitHub compliance — enforced, not remembered (2026-08-31)

The rule is that Actions are disabled at the **repo API level** on every repo in
`rafael5`, `vista-forge` and `m-dev-tools`, so a workflow file arriving by merge,
scaffold or copy still cannot run. Nothing enforced it.

**The hole: a newly created GitHub repo has Actions ENABLED by default.** Every
new repo therefore started non-compliant until somebody noticed. Found when
`rafael5/zmint` was created on 2026-08-31; the first estate-wide sweep then found
`rafael5/rsm-silicon` in the same state, which nobody had noticed at all.

    gh-actions-guard            report drift across all three owners; exit 1 if any
    gh-actions-guard --fix      disable Actions wherever they are on
    gh-actions-guard --quiet    only drift (for cron)

`gh-actions-guard-cron` runs it Mondays 04:10 and pages via ntfy on drift. It
**reports only and never `--fix`es**: disabling Actions is an outward-facing
change to a remote, and a cron job should not make unattended writes to GitHub —
the operator runs `--fix`.

**This is a SYNC-time tool, never a gate.** It talks to GitHub, so it is
scheduled on Monday, the same day as the org's sanctioned network lane, and it
must never appear in a `make check` path.

Baseline at first run: **96 repos, 1 with drift, now 0.**
