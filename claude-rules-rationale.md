# Rationale for the machine-wide Claude rules

`~/.claude/CLAUDE.md` is loaded into **every** session, in every directory, so it
carries the **binding form** of each machine-wide rule and nothing else. This
file carries the arguments and the precedents behind them — the material a
session needs only when it is about to challenge a rule or apply one to a case
the short form does not obviously cover.

Same split as the no-stubs rule already uses
(`~/vista-forge/vdb-explorer/docs/design/no-dangling-artifacts.md`): rule in
CLAUDE.md, reasoning here.

---

## The vista-forge ↔ ~/projects boundary

Argued out in full on **2026-08-17**. Not an open question; no future session
reopens it. The binding rule is in CLAUDE.md — this is why it says what it says.

### Why the arrow is one-way

`~/vista-forge/` is **100 % accountable** for the behaviour of every repo and
every line of code in it: continuous integration, gate checking, quality
controls, the ruling register, the increment protocol. That accountability is
the point of the org. It only holds if nothing inside it depends on something
outside it — a gate that reaches out of the org is a gate that cannot certify
its own result.

`~/projects/` is deliberately none of those things. Exploratory work and
analysis is *slower* under org ceremony and no safer, so the org's rules stop at
its door.

### The four forbids — each was actually attempted, and corrected

- **Never register a `~/projects` decision in an org register.** A register row
  claims the org's gate can verify the evidence. The gate can never verify a
  path outside the org, so the row can only ever print `UNCHECKED` — an
  unresolvable claim, and enough of them erode the register itself. Rules about
  a project tool's behaviour get enforced in that project, by its own tests.
  *Precedent: v-db `VD-D87…D91` were withdrawn for exactly this. The category
  error was the model's, not the operator's.*
- **Never make an org gate, script, guide or artifact depend on a project repo.**
  Same reason as above: the dependency is one-way and read-only.
- **Never apply org ceremony to a project repo** because it "feels"
  org-adjacent — no increment protocol, no in-org memory, no ecosystem entry, no
  `m-*`/`v-*` name.
- **A decision record may still live in the org** when it is about an ORG
  artifact — *how a v-db bundle should be read* belongs with v-db. What must not
  live there is a claim about how the project's code behaves.

### Why the placement test is "operational or exploratory"

It is the same call as the org's own `exploratory-analytics-outside-org` rule.
It is restated machine-wide so it binds in a `~/projects` session, which never
loads the org rules at all.

### Admission — why it is not a loophole

Amended **2026-08-18**, when `~/projects/vdb-bundle-explorer` became
`~/vista-forge/vdb-explorer` (v-db `VD-D93`, superseding `VD-D86`). Recorded
here because a session reading "settled, never relitigate" will otherwise
conclude that move was illegitimate.

1. **Admission is a ruling, not a drift.** Recorded in the owning repo's
   register with the superseded row named. The repo enters **non-waterline**:
   `workspace/repos.txt` only — no `m`/`v` layer tag, no `ecosystem.json` entry,
   no `m arch check`. Same standing as `vista-atlas`, `vista-compass`,
   `m-vscode`, `forge-mcp`.
2. **The discriminator is what the repo CONSUMES, not how useful it is.** A
   viewer over a *published, contracted* artifact can be admitted — vista-atlas
   over the vdocs data release, vdb-explorer over a `dd-bundle`. Free-form
   analytics over a corpus or a retired pipeline stays out, which is why
   `national-dd` and `ndd-explorer` **left** the org on 2026-08-17, one day
   earlier. That decision is not disturbed by this one.
3. **Admission does not make the arrow bidirectional.** *Nothing in vista-forge
   may come to depend on an admitted repo*, and a missing fact is still an
   export request a human opens. That half of the boundary is not amendable by
   admission — it is the reason admission is safe at all.

---

## History cut from CLAUDE.md in the 2026-09-22 trim

`~/.claude/CLAUDE.md` was trimmed from 26.8 KB on 2026-09-22 so it costs less
context in every session. Every rule stayed. The full pre-trim text is
`~/.claude` (repo `minty-claude`) commit `e3bcfa9`, path `CLAUDE.md`. Evidence
already recorded elsewhere was cut with a pointer: the `FILESYSTEM.md`
retirement and the memory-symlink count are in `~/scripts/machine-setup.md`; the
no-stubs precedents are in
`~/vista-forge/vdb-explorer/docs/design/no-dangling-artifacts.md`; the Go module
wiring is in `~/vista-forge/workspace/env.sh`. What follows is recorded nowhere
else.

### Filesystem

- `vista-atlas` and `vista-compass` joined vista-forge as non-waterline repos on
  2026-07-05, when the VistA-Copilot org was retired; `vdb-explorer` joined
  2026-08-18.
- The layout line said "where vista-info-hub / vdocs-* land is an open
  question". It was dropped as stale: the same file already recorded
  vista-info-hub's deletion as history in the org's `docs` repo.
- The old `m-project` / `m-vista-client` templates are retired; a new `m-*` repo
  is modelled on `m-stdlib` or the in-org `go-cli-template`, and a new `v` domain
  uses `v new` (binding form: the org rules).

### Go

In vista-forge, `workspace/env.sh` exports `GOPROXY=file://…` + `GOSUMDB=off`;
there is no `GOFLAGS=-mod=mod` under the org-root `go.work`, where workspace mode
is readonly. The org is trunk-based; the old branch→PR→squash flow once
described here was stale.

### Node

The Node version contract is deliberately not restated in CLAUDE.md: a second
hand-written copy of a contract that already has a generator and a gate is
exactly the drift the no-stubs rule forbids.

### RSM

The frozen rule is stated machine-wide as well as in the org because a session
anywhere may otherwise propose RSM work.

### Model and output tuning

- Opus 5 writes longer responses, narrates more and delegates more readily than
  Opus 4.8 did. None of that is a reasoning limit — it is output volume, so it
  is prompt-tunable; hence the output-tuning section.
- The Opus 5 → Fable 5 gap is narrower than 4.8 → Fable 5 was, so "flag when
  Fable would help" should fire less often than it used to. State selection
  lives in trackers/memory, so a mid-effort model swap carries over cleanly.
- `effortLevel` was not exposed in the `/config` TUI as of Claude Code 2.1.219.
  A `~/.bashrc` alias (`claude --effort high`) covers terminal launches only,
  because the VS Code extension never sources the login shell; the last
  `--effort` on the command line wins.
- "Plain English, never ruling codes" is Rafael's directive of 2026-09-11; its
  example of unexplained jargon was "lane record".

### Memory and skills

- The retired `~/claude/` repo's history is archived at
  `git@github.com:rafael5/claude.git`.
- The `vista-fileman` skill was renamed `fileman` on 2026-07-23.
- `f-stdlib` was a third generated stdlib skill until its repo was retired and
  archived on 2026-09-07; the skill was removed from `~/.claude/skills/` and
  from the installer's list.

### Second pass, 2026-09-22 — removed or corrected after checking the box

- **VistA-Copilot line removed.** The org was retired 2026-07-05; `~/vista-copilot/`
  holds only a `vista-copilot-profile` leftover last committed 2026-06-08.
- **`~/m-dev-tools/`** is idle — last commits 2026-08-03 across its repos.
- **"The shared vdocs index misses ~27% of live sections"** came from the
  `vdocs-corpus` skill's 2026-07-24 measurement (13,899 of 52,048 sections empty).
  The vdocs MCP server now states ~89% indexed and 10.5% bare headings, so the
  figure was dropped rather than picking one.
- **"There are no sanctioned exceptions left"** read as contradicting the org
  rules' one exception, the Pages site. Both are true: no workflow FILE is
  sanctioned; the Pages site builds through GitHub's internal pages job.
  `gh-actions-guard` (weekly cron, Monday 04:10) was added as the enforcement.
