# Home Server Filesystem — Python/Bash Development with Claude

**Host:** Linux Mint, 32GB RAM, 1TB SSD
**Purpose:** Hobbyist Python/Bash/Go/M development, TDD, Claude CLI collaboration
**Last updated:** 2026-07-04

---

## Directory Tree

```
~/
├── .claude/                        # Claude Code config (auto-managed, do not edit manually)
│   ├── CLAUDE.md                   # Global Claude instructions — read on every session
│   ├── settings.json
│   └── settings.local.json
│
├── claude/                         # Claude workspace — skills, templates, memory (git repo)
│   ├── templates/                  # TDD project scaffolds — never hand-craft a layout
│   │   └── python/  go/  node/     # (each ships its own CLAUDE.md + <lang>-dev-guide.md)
│   ├── memory/                     # Claude persistent memory files
│   ├── CLAUDE.md                   # Workspace-level Claude context
│   ├── GUIDE.md                    # Human-readable guide to this workspace
│   ├── CHANGES.md                  # Why things changed — decisions and intent journal
│   ├── TASKS.md                    # Pending tasks requiring minty or deferred execution
│   └── FILESYSTEM.md               # This document
│
├── projects/                       # Active *personal* projects — each subdir an independent git repo
│   ├── README.md                   # Index/overview of ~/projects (workflow, toolchain)
│   ├── fileman-docs/               # docs-as-code master for VA FileMan (DI 22.2) manuals
│   ├── music-library/              # Music metadata enrichment (MusicBrainz/AcoustID/Last.fm)
│   ├── vdocs/                      # VDL → gold markdown corpus + index.db (Python pipeline)
│   ├── vdocs-cli/                  # Go schema-first CLI over the vdocs corpus
│   ├── vdocs-web/                  # Go offline web navigator for the vdocs corpus
│   ├── VistA-DataLoader-fork/      # Fork of ISI's VistA DataLoader
│   ├── vista-meta/                 # Deterministic VistA data+code model on VEHU (public, MIT)
│   │
│   └── archive/                    # !! RETIRED REPOS — read-only; see archive/README.md !!
│       └── ...                     # Superseded by vista-forge Go tools / MSL-VSL stack, etc.
│
├── vista-forge/                    # vista-forge org workspace (NOT under ~/projects — see below)
│   └── m-cli, m-stdlib, m-driver-sdk, m-iris, m-ydb, v-pkg, v-cli, v-stdlib, docs, …
│
├── vista-copilot/                  # VistA-Copilot org workspace (read-only VistA navigators)
│   └── vista-info-hub, … (vdocs-* transfer pending)
│
├── m-dev-tools/                    # LEGACY M-toolchain org — winding down; m-tools/ off-limits
│
├── scripts/                        # Shared bash scripts — single git repo
│   ├── bin/                        # Executable scripts — this dir is on $PATH
│   │   └── *.sh
│   ├── lib/                        # Sourced helper libraries (not on PATH)
│   ├── CLAUDE.md                   # Claude context for the scripts repo
│   ├── GUIDE.md                    # Human-readable guide to the scripts collection
│   └── CHANGES.md                  # Why things changed — decisions and intent journal
│
└── data/                           # Persistent data — NOT git controlled, backed up separately
    ├── vdocs/                      # vdocs corpus lake — state.db, index.db, CAS, gold markdown
    ├── kids-patches/               # WorldVistA/VistA git clone (KIDS corpus for v-pkg sweeps)
    ├── music/                      # music-library SQLite
    └── <project>/                  # one subdir per data-owning project
```

---

## Directory Purposes

### `~/.claude/`
Auto-managed by Claude Code. The `CLAUDE.md` here is the **global user-level instruction file** — Claude reads it at the start of every session regardless of working directory.

> **`~/.claude/CLAUDE.md` is the one and only global instruction file — edit it
> directly.** There is no symlink and no second copy.
>
> *History (2026-07-21): this section used to claim `~/.claude/CLAUDE.md` was a
> symlink to `~/claude/CLAUDE.global.md` and told sessions never to edit it
> directly. That was false — they were independent files that had diverged by
> 238 lines, so every edit made per those instructions changed nothing.
> `CLAUDE.global.md` was deleted; git holds its history.*

### `~/scripts/` — the home-server repo
Version-controlled (`git@github.com:rafael5/scripts.git`). The machine's own
repo: its tooling and the docs that describe it.
- **`bin/`** — shared bash tooling, on `$PATH` (`new-py-project`, `new-go-project`,
  `claude-status`, `install-go.sh`, …)
- **`templates/{python,go,node}`** — TDD project scaffolds; copy one to start a
  new personal project. Never hand-craft a layout.
- **`FILESYSTEM.md`** — this document; the single owner of the machine layout
- **`project-bootstrap-guide.md`** — how the bootstrap + status scripts work
- **`*-guide.md`** — per-topic machine how-tos (git ssh, firefox, gdrive, …)
- **`CHANGES.md`** — decisions and intent journal

This repo is **not** a Python package. It has no pyproject.toml or venv.

> *Retired 2026-07-25: `~/claude/` was a second home-server repo whose name
> implied it owned Claude settings — it never did. Its templates, `FILESYSTEM.md`
> and journal moved here; its `GUIDE.md`, `TASKS.md`, `memory/` and generated
> `STATUS.md` were dropped as stale or superseded. History is archived at
> `git@github.com:rafael5/claude.git`. Claude's real config is `~/.claude/`.*

### Skills — loading convention

Every project `CLAUDE.md` lists its relevant skills with full paths:

```markdown
## Skills
- `~/.claude/skills/vdl/` — VDL catalog domain knowledge
- `~/.claude/skills/vdocs-pipeline/` — pipeline operating manual
```

Claude reads this at session start and loads the listed skills. Skills not listed
in the project's CLAUDE.md will not be loaded automatically.

Every skill must have YAML frontmatter with `name`, `type`, and `description`.
The `description` is what Claude matches against to decide whether to trigger
the skill mid-session. Without frontmatter, the skill cannot auto-trigger.

### `~/.claude/skills/` — Two types of skills

**Tool skills** (`type: tool`) — procedural. Tell Claude *how* to do a specific task.
Examples: `bash-quality-checker`, `pi-system-precheck`, `knowledge-capture`

**Knowledge skills** (`type: knowledge`) — declarative. Tell Claude *what* is known
about a data domain, system, or API. Grows over time as projects are worked.
Examples: `vdl` (VA Document Library domain knowledge)

Every skill has a `SKILL.md` with a frontmatter `description` field — that is what
Claude reads to decide whether to load the skill for a given session.

**To save new knowledge after a project session:**
> "Capture what we learned today" — triggers the `knowledge-capture` skill,
> which extracts durable facts and writes them into the appropriate skill file.

### `~/projects/`
Active *personal* projects live here. Each subdirectory is an independent git repo,
built from a `~/scripts/templates/` scaffold (python / go / node) unless it's an
external fork. Code only — persistent data lives in `~/data/`.

M work is the exception: it is self-contained in `~/vista-forge/` and uses no
external template — model a new `m-*` repo on `m-stdlib` or the in-org
`go-cli-template`, and a new `v` domain on `v new`.

`~/projects/README.md` is a human-readable index of the projects directory itself
(workflow + toolchain). Each project subdir then has its own `CLAUDE.md` / `GUIDE.md`.

**Consolidation note (May–July 2026):** most of the first-generation projects that
used to live here (fm-web, m-parser/tree-sitter-m, m-standard, ydb, vista-docs v1
family, the py-kids-* pair, irisctl/ydbctl, vehu-docker-dev, vista-cli, …) were
superseded by the modern MSL/VSL stack (m-stdlib `STD*` + v-stdlib `VSL*`) and the
production-grade Go toolchain in the **vista-forge** org, or concluded as
experiments. They were moved to `~/projects/archive/` (see its README for the
per-project reasons), deleted outright (vista-docs v1 family), or live on in the
org workspaces.

**Active projects (2026-07-04):**

| Project | Stack | GitHub | Notes |
|---|---|---|---|
| `fileman-docs` | docs-as-code (md) | rafael5/fileman-docs | Quality-improved single-source rewrite of the VDL FileMan (DI 22.2) manuals |
| `music-library` | Python (uv) | _local_ | MusicBrainz/AcoustID/Last.fm enrichment |
| `vdocs` | Python (uv) | rafael5/vdocs | v2 pipeline: VDL → gold markdown corpus + `index.db`; supersedes vista-docs v1 |
| `vdocs-cli` | Go | rafael5/vdocs-cli | Schema-first read-only CLI over the vdocs corpus |
| `vdocs-web` | Go | rafael5/vdocs-web | Offline web navigator over the vdocs corpus (won over the retired vdocs-tui) |
| `VistA-DataLoader-fork` | M + Delphi (fork) | fork of WorldVistA | Data loader; decompose/install via v-pkg |
| `vista-meta` | Python + Docker + M | rafael5/vista-meta (public, MIT) | Deterministic VistA data+code model on VEHU; VSCode ext + CLI |

(The `vdocs-*` repos are slated for transfer to the VistA-Copilot org.)

**Rule: *personal* project repos live under `~/projects/`.** Never create a personal project repo loose in `~/`, `~/scripts/`, etc. If one drifts to the wrong place (e.g. `~/myapp/`), push any unpushed commits, pull into `~/projects/myapp/`, and delete the stray copy.

**Exception — the VistA org workspaces (do NOT relocate into `~/projects/`).** The VistA tooling orgs deliberately live in their own top-level workspaces: **`~/vista-forge/`** (the *actuator* org — `m-*` / `v-*` engine tooling) and **`~/vista-copilot/`** (the *navigator* org — `vista-info-hub`, `vdocs-*`). These are correct where they are; the "pull stray repos into `~/projects/`" rule does **not** apply to them. Split by purpose: *actuate* (does things to a live VistA engine) vs *navigate* (read-only VistA info). See `~/.claude/CLAUDE.md` § "VistA tooling: two orgs — actuate vs navigate".

### `~/projects/archive/`
**Retired projects. Claude must skip this directory entirely unless explicitly asked.**
- Full git repos (history + remotes preserved), but unmaintained, ungated, may not run
- Per-project index — what each was, why archived, what superseded it —
  in `~/projects/archive/README.md`
- Kept for reference only (e.g. py-kids-vc is v-pkg's validated codec oracle);
  do not migrate or process unless explicitly asked

### `~/scripts/`
One git repo for all shared bash scripts. `~/scripts/bin/` is on `$PATH` — scripts here are callable from any project, terminal, or Claude session. `lib/` holds sourced helper libraries.

### `~/data/`
Persistent data that must never be committed to git: databases, large files, API outputs, documents. Each active project gets its own subdirectory. **Not a git repo.** Back up separately from code.

---

## Shell Setup

Add to `~/.bashrc`:

```bash
# Shared scripts on PATH
export PATH="$HOME/scripts/bin:$PATH"

# direnv hook (auto-activates .venv on cd into a project)
eval "$(direnv hook bash)"

# uv (Python package manager)
export PATH="$HOME/.local/bin:$PATH"
```

---

## Starting a New Project

Use the bootstrap scripts in `~/scripts/bin/` — they handle the template
copy, package rename, data dir creation, git init, GitHub remote setup,
auto-memory symlink, and `make install` in one shot. Manual recipe is below
for reference only; in practice you should not need it.

```bash
new-py-project myapp                       # full bootstrap, ready to commit
new-py-project mytool --no-data --no-remote  # quick local-only project
new-go-project mycli                       # Go equivalent
new-go-project mycli --data                # Go project that owns ~/data/<name>
```

What the scripts do:

1. Copy `~/scripts/templates/{python,go}` to `~/projects/<name>/`
2. Rename the package (`myproject` → `<name>` / `<pkg>`) in source, tests,
   and `pyproject.toml` / `go.mod` / `Makefile`
3. Create `~/data/<name>/{input,output,db}` (Python default; Go opt-in via `--data`)
4. `git init -b main` and `git remote add origin git@github.com:rafael5/<name>.git`
   (skip remote with `--no-remote`)
5. (Historical: the scripts used to symlink the auto-memory dir to
   a real per-project dir. The memory model is **no-symlink** — per-project
   memory lives in the real dir `~/.claude/projects/<hash>/memory/`; see
   `~/.claude/CLAUDE.md` § Memory. Skip/ignore any symlink step.)
6. Run `make install` + `make test` (skip with `--no-install`)

After bootstrap, the manual remaining steps are: edit code, commit, and
optionally `gh repo create rafael5/<name> --public --source . --remote origin`
followed by `git push -u origin main`.

### Manual recipe (for the rare case the script doesn't fit)

```bash
# Python — same as new-py-project does internally
cp -r ~/scripts/templates/python ~/projects/myapp
cd ~/projects/myapp
mv src/myproject src/myapp
sed -i 's/myproject/myapp/g' pyproject.toml tests/conftest.py tests/test_myproject.py
mv tests/test_myproject.py tests/test_myapp.py
mkdir -p ~/data/myapp/{input,output,db}
git init -b main && git remote add origin git@github.com:rafael5/myapp.git
make install && make test
```

---

## Workspace Status — `claude-status`

Run `claude-status` (in `~/scripts/bin/`) at the start of any session to
get a one-screen orientation across every project under `~/projects/`:
branch, dirty file count, ahead/behind vs origin, last commit, and a
"current focus" line pulled from that project's `~/.claude/projects/<hash>/memory/MEMORY.md`.

```bash
claude-status              # print to stdout (read-only, no network)
claude-status --fetch      # opt-in `git fetch` first so ahead/behind is fresh
claude-status --write      # also write ~/data/claude-status/STATUS.md (gitignored)
```

The focus line comes from the first content under a `## Status`,
`## Current focus`, `## Next`, `## Setup status`, or `## Last session`
heading (or the YAML `description:` if none of those exist). Project names
map to memory files via `<name>` → `project_<name with underscores>.md`,
with a glob fallback to `project_<name>_*.md` when the direct file is
missing. Files "owned" by a more specific project are skipped so e.g.
`vista-docs` doesn't pull from `project_vista_docs_api.md`.

---

## GUIDE.md Convention

Every git repo on this machine includes a `GUIDE.md` — a human-readable introduction to the project. It is written for people, not for Claude.

| File | Audience | Purpose |
|---|---|---|
| `CLAUDE.md` | Claude | Session context, data paths, constraints, Claude-specific instructions |
| `GUIDE.md` | Humans | How the project works, how to run it, key concepts, quick reference |

`GUIDE.md` typically covers: what the project does, how to set it up, how to run/test it, and a tour of the key files or commands. Length and depth match the project's complexity.

---

## Project CLAUDE.md Convention

Every project's `CLAUDE.md` must include a **Data paths** section:

```markdown
## Data paths
- Input files:  ~/data/myapp/input/
- Output files: ~/data/myapp/output/
- Database:     ~/data/myapp/db/myapp.db
```

---

## How Claude Navigates This Structure

When starting a session on any project, tell Claude:

> "Read ~/scripts/FILESYSTEM.md, then read this project's CLAUDE.md."

Claude will then know:
- Where the template lives and how to apply it
- Where shared bash scripts are and how to call them
- Where persistent data lives for this project
- Which skills are available in `~/.claude/skills/`
- That `~/projects/archive/` is off-limits unless explicitly asked

---

## Conventions

| Convention | Rule |
|---|---|
| One venv per project | Always `~/projects/myapp/.venv/`, never shared |
| Data outside the repo | Always `~/data/myapp/`, never inside `~/projects/` |
| Shared bash scripts | Add to `~/scripts/bin/`, callable by name from anywhere |
| New Python project | Always copy from `~/scripts/templates/python/` into `~/projects/` |
| Git remotes | Personal repos push to `git@github.com:rafael5/`; org repos to `vista-forge` / `VistA-Copilot` / `m-dev-tools` |
| Secrets | Always in `~/projects/myapp/.env`, never committed |
| Archive | `~/projects/archive/` — read-only, Claude ignores unless asked; index in its README.md |
| Persistent memory | Global prefs in `~/.claude/CLAUDE.md`; per-project in `~/.claude/projects/<hash>/memory/`; org repos may redirect in-org. the legacy shared store was retired 2026-07-25 |
| GUIDE.md | Every git repo has one — human-readable project guide (not for Claude) |
| CHANGES.md | Every git repo has one — decisions and intent journal (why, not what) |

---

## Backup Strategy

| What | Where | Strategy |
|---|---|---|
| Code | `~/projects/` (active), `~/scripts/`, `~/vista-forge/` | Git push to GitHub |
| Data | `~/data/` | rsync to external drive or NAS |
| Config | `~/.bashrc`, `~/.ssh/`, `~/.claude/` | rsync to external drive |
| Archive | `~/projects/archive/` | rsync (repos keep remotes but are frozen — no further pushes) |
