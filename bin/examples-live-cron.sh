#!/usr/bin/env bash
# Nightly LIVE-tier living-examples cadence (Living Executable Examples E4 / L4),
# run from system cron on minty — the local-engine equivalent of the .github
# examples-live.yml workflow (which needs a self-hosted runner because vehu/foia
# are local). For each *-stdlib repo: regenerate examples/REPORT.md by running the
# EX programs on the LIVE engines (vehu + foia) through the driver stack, then
# commit + push the refreshed REPORT. Fail-soft: a red run reds REPORT.md but the
# job still exits 0 (the bare tier in CI is the hard gate).
#
# Three fail-soft tiers run in this ONE nightly (QC-C cadence wiring):
#   - live MSL suites     -> examples/LIVE-QC.md              (QC-B, per stdlib repo)
#   - living examples     -> examples/REPORT.md               (E4,   per stdlib repo)
#   - m-cli surface sweep -> m-cli/examples/SURFACE-SWEEP.md  (QC-A, --live)
# The last one's `generated:` line is the anchor the WEEKLY meta-gate freshness
# check hard-gates on (reds if > 48 h old = this cron silently died).
#
# crontab (crontab -e):
#   30 6 * * *  /home/rafael/scripts/bin/examples-live-cron.sh
#
# Headless git push: cron has no keyring/D-Bus, so `gh auth git-credential`
# (which backs the https push helper) can't read gh's keyring token. Drop a PAT
# with contents:write into ~/.config/examples-live.env (chmod 600):
#   GH_TOKEN=github_pat_xxx
# The existing `!gh auth git-credential` helper uses $GH_TOKEN when set — no
# keyring needed. Without it the wrapper still commits locally and logs the
# push failure (push it yourself later).
set -uo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin"
M="$HOME/vista-forge/m-cli/dist/m"
ENV_FILE="$HOME/.config/examples-live.env"
LOG="$HOME/data/living-examples/cron.log"
mkdir -p "$(dirname "$LOG")"

# Source the PAT for headless push (optional; see header).
[ -r "$ENV_FILE" ] && . "$ENV_FILE" && export GH_TOKEN

{
  echo "==================== $(date -Is) examples-live ===================="
  for repo in m-stdlib v-stdlib; do
    dir="$HOME/vista-forge/$repo"
    [ -d "$dir" ] || { echo "skip $repo (no checkout)"; continue; }
    cd "$dir" || continue
    echo "---- $repo ----"
    git pull --ff-only 2>&1 | tail -1 || echo "  (pull skipped/failed — continuing)"
    # QC-B: live MSL *suite* tier — run the test SUITES on the live engines
    # (vehu YDB + foia IRIS VISTA ns) BEFORE the examples step, writing
    # examples/LIVE-QC.md. Fail-soft like the examples tier. Guarded: only repos
    # that define the target run it (m-stdlib today; v-stdlib once it graduates
    # the sibling tool). `make -n` is a cheap has-target probe.
    if make -n live-qc >/dev/null 2>&1; then
      make live-qc M="$M" 2>&1 | tail -4
    else
      echo "  (no live-qc target in $repo — skipping the live suite tier)"
    fi
    make examples-run-live M="$M" 2>&1 | tail -5
    # Commit whichever live artifact(s) the run refreshed (REPORT.md +
    # LIVE-QC.md). Both are fail-soft run snapshots — a red is a committed diff.
    changed=""
    for art in examples/REPORT.md examples/LIVE-QC.md; do
      [ -n "$(git status --porcelain -- "$art")" ] && changed="$changed $art"
    done
    if [ -n "$changed" ]; then
      git add -- $changed
      git commit -q -m "chore(examples): refresh live REPORT.md + LIVE-QC.md (nightly cadence)"
      if git push 2>&1 | tail -1; then
        echo "  pushed refreshed live artifacts:$changed"
      else
        echo "  PUSH FAILED (auth? set GH_TOKEN in $ENV_FILE) — committed locally"
      fi
    else
      echo "  live artifacts unchanged — nothing to commit"
    fi
  done
  # QC-C: fold the m-cli command-surface sweep (QC-A) into the SAME nightly run
  # (not a second cron). Runs the sweep with --live — engine/driver/sync probes
  # against vehu + foia through the driver stack — and writes the committed
  # markdown artifact examples/SURFACE-SWEEP.md, whose `generated:` line the
  # weekly meta-gate freshness check parses (reds if > 48 h old). Fail-soft: a
  # red sweep still refreshes the report (a red is a committed diff), and
  # `make surface-sweep-report` never aborts the nightly on a non-zero sweep.
  # The arch fold-in needs the sibling repos cloned beside m-cli (they are, under
  # ~/vista-forge) — a missing sibling is reported as skipped, not failed.
  mcli="$HOME/vista-forge/m-cli"
  if [ -d "$mcli" ]; then
    cd "$mcli" || true
    echo "---- m-cli surface-sweep (QC-A, --live) ----"
    git pull --ff-only 2>&1 | tail -1 || echo "  (pull skipped/failed — continuing)"
    make build 2>&1 | tail -2
    make surface-sweep-report ARGS=--live 2>&1 | tail -3
    art="examples/SURFACE-SWEEP.md"
    if [ -n "$(git status --porcelain -- "$art")" ]; then
      git add -- "$art"
      git commit -q -m "chore(qc): refresh live surface-sweep report (nightly cadence)"
      if git push 2>&1 | tail -1; then
        echo "  pushed refreshed $art"
      else
        echo "  PUSH FAILED (auth? set GH_TOKEN in $ENV_FILE) — committed locally"
      fi
    else
      echo "  $art unchanged — nothing to commit"
    fi
  else
    echo "skip m-cli surface-sweep (no checkout)"
  fi
  echo "==================== done $(date -Is) ===================="
} >>"$LOG" 2>&1
exit 0
