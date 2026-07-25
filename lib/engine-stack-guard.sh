#!/usr/bin/env bash
# PreToolUse(Bash) guard — vista-forge m/v waterline, transport monopoly.
#
# WHY: all work against a live M engine — especially the VistA engines
# (YDB-VistA `vehu`, IRIS-VistA `foia*`) and the test engines — MUST go through
# the established m-driver-sdk → m-ydb / m-iris stack via the `m` toolchain
# (`m test --docker <c>`, `m coverage --docker <c>`, `m vista exec`, or
# `mdriver.Client`). Hand-rolling `docker exec <engine> … mumps|iris session`
# (or a bare `mumps -direct` / `iris session` inside the workspace) sidesteps the
# designated stack and is forbidden. This guard makes that a hard, real-time DENY
# so the mistake cannot recur silently. See:
#   ~/vista-forge/CLAUDE.md  (§ m/v waterline → engine-access rule)
#   ~/vista-forge/docs/memory/engine-access-through-driver-stack.md
#
# Only the actual COMMAND SKELETON is matched — heredoc bodies and quoted strings
# (commit messages, echo/printf of docs, this very guard's text) are stripped
# first, so documenting the rule never trips it; only a real engine-exec does.
#
# ESCAPE HATCH (rare, deliberate, visible): include the token `stack-exempt`
# in the command for a one-off read-only inspection that truly cannot use the
# toolchain.
#
# Fails OPEN on any internal/parse error (never block legitimate work because of
# a guard bug — the CLAUDE.md rule + CI gate + memory still backstop it).
set -uo pipefail

GUARD_INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$GUARD_INPUT" ] || exit 0
export GUARD_INPUT

GUARD_INPUT="$GUARD_INPUT" python3 - <<'PY'
import os, sys, re, json

try:
    d = json.loads(os.environ.get("GUARD_INPUT", "") or "{}")
except Exception:
    sys.exit(0)  # fail open

cmd = ((d.get("tool_input", {}) or {}).get("command") or "")
cwd = d.get("cwd", "") or ""
if not cmd:
    sys.exit(0)
if "stack-exempt" in cmd:           # deliberate, visible exemption
    sys.exit(0)

# Reduce the command to its executable SKELETON: drop heredoc bodies and quoted
# spans so engine words inside commit messages / echo / docs don't match.
def strip_heredocs(s: str) -> str:
    for m in re.finditer(r"<<-?\s*[\"']?(\w+)[\"']?", s):
        delim = m.group(1)
        rest = s[m.end():]
        dm = re.search(r"\n[ \t]*" + re.escape(delim) + r"[ \t]*(?:\n|$)", rest)
        if dm:
            s = s.replace(rest[:dm.end()], " ", 1)
    return s

skel = strip_heredocs(cmd)
skel = re.sub(r"'[^']*'", " ", skel)      # strip single-quoted spans
skel = re.sub(r'"[^"]*"', " ", skel)      # strip double-quoted spans

engine = re.compile(r"\b(vehu|foia|vista-iris|m-test-engine|m-test-iris|ydb-test)\b")
docker_exec = re.compile(r"docker\s+(?:-\S+\s+)*exec\b")
interp = re.compile(r"(\biris\s+session\b|\bcsession\b|\bmumps\s+-(?:direct|dir|r)\b"
                    r"|\$gtm_dist\b|\$ydb_dist/(?:yottadb|mumps)\b)")

violation = ""
if docker_exec.search(skel) and engine.search(skel):
    violation = "raw 'docker exec' into a stack engine container"
elif "vista-forge" in cwd and interp.search(skel):
    violation = "a hand-rolled M interpreter (mumps -direct / iris session / $gtm_dist)"

if not violation:
    sys.exit(0)

sys.stderr.write(
    "BLOCKED by engine-stack-guard (vista-forge m/v waterline, transport monopoly):\n"
    "  " + violation + "\n\n"
    "All work against the live M engines (VistA-on-YDB 'vehu', VistA-on-IRIS 'foia*',\n"
    "and the test engines) MUST go through the m-driver-sdk -> m-ydb / m-iris stack via\n"
    "the 'm' toolchain — never raw 'docker exec ... mumps | iris session'. Use instead:\n"
    "  - Tests/suites:  m test --engine ydb  --docker vehu     --routines $MSTDLIB/src <...TST.m>\n"
    "                   m test --engine iris --docker foia-t12 --routines $MSTDLIB/src <...TST.m>\n"
    "                   (or: make test ENGINE=ydb DOCKER=vehu / ENGINE=iris DOCKER=foia-t12)\n"
    "  - Ad-hoc exec:   m vista exec --engine ydb|iris ...  (driver-backed VistaEngine)\n"
    "  - Go code:       mdriver.Client (m-driver-sdk) — the only transport seam.\n\n"
    "Exercising the designated stack at all times is the point. For a genuine one-off\n"
    "read-only inspection that cannot use the toolchain, re-issue the command with a\n"
    "'stack-exempt: <reason>' marker so the exception is deliberate and visible.\n"
)
sys.exit(2)
PY
exit $?
