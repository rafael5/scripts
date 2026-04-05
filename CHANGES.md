# CHANGES

## What this file is

A human-readable log of *why* things changed — intent, decisions, and context
that git diffs and commit messages can't capture on their own. Git records
what changed; this file records why it mattered.

It is not a substitute for commit messages, and not a changelog for end-users.
It is a personal maintenance journal for this repository.

## When to write an entry

- **After a meaningful work session** — one entry per session is enough, even
  if you made a dozen commits. Summarise what you were trying to do and what
  you decided.
- **When you make a non-obvious decision** — chose approach A over B, removed
  something intentionally, deferred something deliberately. Future you will
  not remember why.
- **When something broke and you fixed it** — what the symptom was, what
  caused it, how you resolved it.
- **Not required for** trivial edits (typo fixes, formatting), version bumps
  with no logic change, or anything fully self-explanatory from the commit
  message.

## Entry format

```
## YYYY-MM-DD — Short description of the session or change

What you were trying to accomplish, and any relevant context.

- Specific decision or action taken, and why
- What you tried that didn't work, if useful to record
- Anything left unfinished or deferred, and why

```

## Example entry

```
## 2025-11-14 — Switched package manager from pip to uv

Migrated the project tooling to uv after repeated environment reproducibility
issues with pip + venv across machines.

- Replaced requirements.txt with pyproject.toml managed by uv
- Kept requirements.txt as a lockfile export for compatibility with CI
- Decided NOT to pin transitive deps yet — too noisy, revisit if builds break
- Deferred moving to uv workspaces; overkill for now given single-package structure

```

---

<!-- CHANGES BELOW THIS LINE -->
