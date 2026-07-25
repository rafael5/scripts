#!/usr/bin/env bash
# =============================================================================
#  git-status-reminder.sh
#  Version: 1.0.1
#  Target:  PostToolUse hook for Claude Code (matcher: Bash, if: git commit/push)
#
#  Purpose
#  After Claude runs `git commit` or `git push` via the Bash tool, inject a
#  system reminder into the model context telling it to refresh the workspace
#  status (claude-status) and update the relevant project_<name>.md memory
#  file if its focus line is stale.
#
#  Design
#  Reads the PostToolUse hook input on stdin (JSON: tool_name, tool_input,
#  tool_response, optional cwd). Pulls the command string and cwd, derives
#  the project name from the cwd (first path component under ~/projects/),
#  and emits a JSON envelope with hookSpecificOutput.additionalContext.
#
#  Uses python3 only (no jq dependency). Fail-safe: any parse error emits
#  an empty {} so the hook never blocks the parent tool call. The python
#  source lives in the sibling file git-status-reminder.py — calling it
#  via `python3 <path>` (NOT `python3 - <<EOF`) keeps real stdin available.
#
#  Wired in: ~/.claude/settings.json under hooks.PostToolUse[matcher=Bash]
#  with `if: "Bash(git commit *)"` and `if: "Bash(git push *)"`.
# =============================================================================
exec python3 "$(dirname "$0")/git-status-reminder.py"
