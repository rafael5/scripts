#!/usr/bin/env bash
# =============================================================================
#  engine-container-guard.sh
#  Version: 1.0.0
#  Target:  PreToolUse(Bash) hook for Claude Code — HOST-owned, machine-wide
#
#  Purpose
#  Refuse a raw `docker exec` into one of this box's M engine containers from
#  ANYWHERE outside ~/vista-forge. The engines (vehu, foia*, the test engines)
#  are a HOST resource — long-lived containers holding real databases, quiesced
#  nightly by minty-backup — so protecting them is a host concern, not an org
#  one.
#
#  WHY THIS FILE EXISTS SEPARATELY (2026-08-31)
#  ~/vista-forge/.github/scripts/hooks/engine-stack-guard.sh used to enforce
#  this machine-wide. That inverted the machine's own boundary rule: vista-forge
#  has ZERO JURISDICTION over ~/projects, yet an org-owned hook was adjudicating
#  every command there. The org guard is now scoped to the org, and this host
#  guard covers everywhere else. One rule, one owner, each in its own place.
#
#  DIVISION OF LABOUR — this guard DEFERS inside the org.
#  Inside ~/vista-forge the org guard runs and gives the far better refusal: it
#  names the sanctioned `m` toolchain alternative for what the command was
#  trying to do. Blocking here first would replace that teaching with a blunter
#  message, so this guard exits 0 for any cwd inside the org.
#
#  Escape hatch: same marker as the org guard — include `stack-exempt: <reason>`
#  (colon and a non-empty reason REQUIRED) for a deliberate, visible one-off.
#
#  Fails OPEN on any parse error: a guard bug must never block legitimate work.
# =============================================================================
set -uo pipefail

GUARD_INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$GUARD_INPUT" ] || exit 0

GUARD_INPUT="$GUARD_INPUT" FORGE_ROOT="${FORGE_ROOT:-$HOME/vista-forge}" python3 - <<'PY'
import os, sys, re, json

try:
    d = json.loads(os.environ.get("GUARD_INPUT", "") or "{}")
except Exception:
    sys.exit(0)                                    # fail open

cmd = ((d.get("tool_input", {}) or {}).get("command") or "")
cwd = d.get("cwd", "") or ""
if not cmd:
    sys.exit(0)

# Deliberate, visible exemption: marker AND a non-empty reason.
if re.search(r"stack-exempt:\s*\S", cmd):
    sys.exit(0)

# Defer to the org guard inside the org — it gives the better refusal.
FORGE_ROOT = os.path.realpath(os.environ.get("FORGE_ROOT") or
                              os.path.expanduser("~/vista-forge"))
try:
    rp = os.path.realpath(cwd) if cwd else ""
except Exception:
    rp = ""
if rp and (rp == FORGE_ROOT or rp.startswith(FORGE_ROOT + os.sep)):
    sys.exit(0)

# Same skeleton reduction as the org guard, and the same known limitation: a
# double-quoted span containing escaped quotes is only partly stripped, so a
# JSON payload naming an engine can still trip this. That is the deliberate
# trade — a false positive costs a `stack-exempt:` marker, a false negative
# lets a real engine-exec through.
def strip_heredocs(s):
    for m in re.finditer(r"<<-?\s*[\"']?(\w+)[\"']?", s):
        delim = m.group(1)
        rest = s[m.end():]
        dm = re.search(r"\n[ \t]*" + re.escape(delim) + r"[ \t]*(?:\n|$)", rest)
        if dm:
            s = s.replace(rest[:dm.end()], " ", 1)
    return s

skel = strip_heredocs(cmd)
skel = re.sub(r"'[^']*'", " ", skel)
skel = re.sub(r'"[^"]*"', " ", skel)

engine = re.compile(r"\b(vehu|foia|vista-iris|m-test-engine|m-test-iris|ydb-test)\b")
docker_exec = re.compile(r"docker\s+(?:-\S+\s+)*exec\b")

if not (docker_exec.search(skel) and engine.search(skel)):
    sys.exit(0)

sys.stderr.write(
    "BLOCKED by engine-container-guard (host rule — the M engines are shared "
    "state):\n"
    "  raw 'docker exec' into an engine container, from outside ~/vista-forge\n\n"
    "The engines (vehu, foia*, the test engines) hold real databases and are\n"
    "quiesced nightly by minty-backup. Reaching into one from an exploratory\n"
    "~/projects session can corrupt state that other work depends on.\n\n"
    "If you need engine data here, take it from a committed EXPORT that\n"
    "vista-forge publishes — ~/projects consumes published artifacts, it does\n"
    "not operate the engine (machine CLAUDE.md, the vista-forge boundary).\n\n"
    "If this is genuinely engine work, do it from inside ~/vista-forge with the\n"
    "`m` toolchain. For a deliberate read-only one-off, re-issue with a\n"
    "'stack-exempt: <reason>' marker so the exception is visible.\n")
sys.exit(2)
PY
