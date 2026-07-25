"""PostToolUse hook payload builder for git commit/push reminders.

Reads the hook JSON on stdin and prints a single-line JSON envelope with
hookSpecificOutput.additionalContext that asks Claude to refresh the
workspace status. Called by git-status-reminder.sh — see that file's
header for the full wiring + design notes.
"""

import json
import os
import re
import sys


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        # Never block the parent tool call: emit a no-op envelope.
        print("{}")
        return

    tool_input = data.get("tool_input") or {}
    cmd = tool_input.get("command", "") or ""
    cwd = data.get("cwd") or tool_input.get("cwd") or ""

    home = os.path.expanduser("~")
    projects_root = os.path.join(home, "projects") + os.sep

    # ORG SCOPE-OUT (org-self-containment S5, 2026-07-18): the vista-forge /
    # m-dev-tools orgs route memory IN-ORG (docs/memory per repo, wired by
    # install-memory-links.sh) and their increment protocol persists memory +
    # tracker at every commit — the legacy project_*.md flow this reminder
    # points at actively contradicted that routing. Stay silent there.
    for org_root in ("vista-forge", "m-dev-tools"):
        if cwd.startswith(os.path.join(home, org_root)):
            print("{}")
            return

    # Derive the project name from cwd (first path component under ~/projects/).
    project = ""
    if cwd.startswith(projects_root):
        project = cwd[len(projects_root):].split(os.sep, 1)[0]

    # Fallback: look for `git -C <path>` in the command itself.
    if not project:
        m = re.search(r"git\s+-C\s+(\S+)", cmd)
        if m:
            path = os.path.expanduser(m.group(1))
            if path.startswith(projects_root):
                project = path[len(projects_root):].split(os.sep, 1)[0]

    # Self-gating: only fire for a real `git commit` / `git push`. Anchor the
    # match to a shell command boundary (start of string, or after one of
    # ; & | newline ( — which also covers && and ||) so substrings like
    # `grep "git commit"` or `echo git push` don't trigger. The settings.json
    # `if` clause is no longer relied upon — this script self-gates.
    boundary = r"(?:^|[\n;&|(])\s*"
    git_call = r"git\b(?:\s+-C\s+\S+)*\s+"
    if re.search(boundary + git_call + r"commit\b", cmd):
        action = "git commit"
    elif re.search(boundary + git_call + r"push\b", cmd):
        action = "git push"
    else:
        # Not an actual git commit/push: stay silent (no-op envelope).
        print("{}")
        return

    if project:
        location = f"`~/projects/{project}/` (project: **{project}**)"
        memory_hint = f"`~/.claude/projects/-home-rafael-projects-{project}/memory/MEMORY.md`"
    else:
        location = f"`{cwd or '(cwd unknown)'}`"
        memory_hint = "`~/.claude/projects/<path-hash>/memory/MEMORY.md`"

    reminder = (
        f"A `{action}` just ran via Bash in {location}.\n"
        f"The workspace status table may now be stale.\n\n"
        f"- Run `claude-status` (in `~/scripts/bin/`) to refresh the cross-project view.\n"
        f"- If the FOCUS column for this project looks wrong or out of date, update "
        f"{memory_hint} (the always-loaded summary — usually a one-line tweak under `## Status`).\n"
        f"- Skip both if this commit/push was a trivial change (typo, formatting) "
        f"or if the focus line is already current."
    )

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": reminder,
        },
        "suppressOutput": True,
    }))


if __name__ == "__main__":
    main()
