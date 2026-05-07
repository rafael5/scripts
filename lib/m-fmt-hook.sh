#!/usr/bin/env bash
# PostToolUse hook for Edit/Write/MultiEdit on .m files:
#   1. Auto-format silently via `m fmt` (per-project .m-cli.toml drives style —
#      pythonic-lower for modern projects, VistA conventions for VistA).
#   2. Run `m lint --error-on=error` and surface errors back to Claude via
#      hookSpecificOutput.additionalContext, so Claude sees real issues and
#      can fix them mid-turn.
# Best-effort throughout: if `m` is missing, exit silently — never block.
set -uo pipefail

M="$HOME/projects/m-cli/.venv/bin/m"
[ -x "$M" ] || exit 0

# Accumulate lint output across all touched .m files in this tool call.
lint_report=""

# Claude Code passes the affected file path(s) as $CLAUDE_FILE_PATHS
# (space-separated). For Write/Edit it's typically a single path.
for f in ${CLAUDE_FILE_PATHS:-}; do
  case "$f" in
    *.m)
      [ -f "$f" ] || continue
      # m fmt / m lint discover .m-cli.toml from cwd, not from the file
      # path, so cd into the file's parent. Subshell isolates the cd.
      ( cd "$(dirname "$f")" && "$M" fmt "$f" >/dev/null 2>&1 ) || true
      lint_out=$( cd "$(dirname "$f")" && "$M" lint --error-on=error "$f" 2>&1 )
      lint_rc=$?
      if [ "$lint_rc" -ne 0 ] && [ -n "$lint_out" ]; then
        lint_report+="--- m lint ${f#$HOME/} (rc=$lint_rc) ---
$lint_out

"
      fi
      ;;
  esac
done

# If any file failed lint, emit JSON so Claude sees the report as
# additionalContext — appears in the next turn as a system reminder.
if [ -n "$lint_report" ]; then
  python3 -c '
import json, sys
ctx = sys.stdin.read()
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": ctx,
    }
}))
' <<< "$lint_report"
fi

exit 0
