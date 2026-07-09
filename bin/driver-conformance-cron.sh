#!/usr/bin/env bash
# Nightly driver-contract conformance cadence (driver-contract.md §9), run from
# system cron on minty — the local-engine equivalent of the .github
# driver-conformance.yml workflow (which needs a self-hosted runner because the
# engines are local). For each driver repo, drive the built binary over the
# subprocess+JSON seam against its live test engine via `make conformance`, then
# write + commit a stamped conformance/REPORT.md. The `generated:` line is the
# anchor the WEEKLY meta-gate freshness check hard-gates on (reds if > 48 h old =
# this cron silently died) — the same self-monitoring pattern as the surface-sweep
# report. Fail-soft: a non-conformant driver reds the committed REPORT but the job
# still exits 0 (the workflow_dispatch conformance.yml is the hard on-demand gate).
#
# crontab (crontab -e):
#   45 4 * * *  /home/rafael/scripts/bin/driver-conformance-cron.sh
#
# Headless git push: cron has no keyring, so reuse the same PAT file the
# examples-live cron uses. Drop a PAT with contents:write into
# ~/.config/examples-live.env (chmod 600):  GH_TOKEN=github_pat_xxx
# Requires the test engines up (m-test-engine YDB, m-test-iris IRIS) and the
# M_<ENGINE>_* env — sourced from ~/data/vista-forge/auth.env like every engine
# path on this host.
set -uo pipefail

# /usr/local/go/bin holds the `go` toolchain — `make conformance` runs `go build`
# + `go run`, so unlike examples-live-cron (which uses a prebuilt `m`), the go
# toolchain MUST be on PATH or the nightly fails with `go: command not found`.
export PATH="/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/go/bin"
ENV_FILE="$HOME/.config/examples-live.env"
AUTH_ENV="$HOME/data/vista-forge/auth.env"
LOG="$HOME/data/driver-conformance/cron.log"
mkdir -p "$(dirname "$LOG")"

# Headless-push PAT (optional) + engine/VistA creds (for the remote IRIS path).
[ -r "$ENV_FILE" ]  && . "$ENV_FILE" && export GH_TOKEN
[ -r "$AUTH_ENV" ]  && set -a && . "$AUTH_ENV" && set +a

{
  echo "==================== $(date -Is) driver-conformance ===================="
  for repo in m-ydb m-iris; do
    dir="$HOME/vista-forge/$repo"
    [ -d "$dir" ] || { echo "skip $repo (no checkout)"; continue; }
    cd "$dir" || continue
    echo "---- $repo ----"
    git pull --ff-only 2>&1 | tail -1 || echo "  (pull skipped/failed — continuing)"

    # Run the gate, capturing the human report + the exit code. `make conformance`
    # prints the per-check PASS/FAIL table to stdout and exits non-zero on drift.
    out="$(make conformance 2>&1)"; rc=$?
    echo "$out" | tail -6
    [ "$rc" -eq 0 ] && verdict="CONFORMANT" || verdict="NON-CONFORMANT (exit $rc)"

    # Write the stamped, always-changing report (the freshness anchor). RFC3339
    # `generated:` line so the file re-commits every run and the weekly meta-gate
    # can measure staleness.
    art="conformance/REPORT.md"
    mkdir -p conformance
    {
      echo "# $repo — driver-contract conformance (nightly)"
      echo
      echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "verdict: $verdict"
      echo
      echo '```'
      echo "$out"
      echo '```'
    } > "$art"

    if [ -n "$(git status --porcelain -- "$art")" ]; then
      git add -- "$art"
      git commit -q -m "chore(conformance): refresh nightly driver-conformance REPORT ($verdict)"
      if git push 2>&1 | tail -1; then
        echo "  pushed refreshed $art ($verdict)"
      else
        echo "  PUSH FAILED (auth? set GH_TOKEN in $ENV_FILE) — committed locally"
      fi
    else
      echo "  $art unchanged — nothing to commit"
    fi
  done
  echo "==================== done $(date -Is) ===================="
} >>"$LOG" 2>&1
exit 0
