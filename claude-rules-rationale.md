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
