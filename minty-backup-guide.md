# minty-backup — guide

Three scripts implementing the machine backup design. **Canon is
`~/projects/minty/docs/minty-backup-proposal.md`** — this file is operational
only; it says how to run them, not why they are shaped this way.

| Script | Runs as | Cadence | Job |
|---|---|---|---|
| `minty-backup` | root | nightly 23:00 | borg → USB drive, then rclone → cloud |
| `minty-backup-check` | root | weekly Sat 07:00 | the §4.3 verification calendar + SMART |
| `minty-backup-watch` | rafael | daily 05:35 | reads the stamps, pushes ntfy when one is stale |

## The one idea

Every script stamps **green only**. Nothing is refreshed unless the phase
actually succeeded, so **staleness is the alarm** — `minty-backup-watch` is the
only thing that talks to ntfy on a schedule, and silence means healthy. The
failure this design exists to prevent is not data loss, it is a green stamp
over a broken backup.

```
/var/lib/minty-backup/STAMP.borg     nightly borg run        stale after 36 h
/var/lib/minty-backup/STAMP.rclone   nightly offsite copy    stale after 36 h
/var/lib/minty-backup/STAMP.check    weekly verification     stale after 10 d
```

## Config

`/etc/minty-backup.env`, root:root, **0600** — it holds `BORG_PASSPHRASE`.
Template: `~/projects/minty/etc/minty-backup.env.example`.

```bash
sudo install -m 0600 -o root -g root \
  ~/projects/minty/etc/minty-backup.env.example /etc/minty-backup.env
sudo nano /etc/minty-backup.env
```

The passphrase in that file is a *convenience copy*. The authoritative one
lives off-box, because this file is inside the machine you are trying to
recover (proposal §5.0).

`minty-backup-watch` reads `NTFY_TOPIC`/`NTFY_SERVER` from
`~/data/vista-forge/auth.env` — reusing the alarm channel is sanctioned; the
backup facility itself deliberately does not live in the org (D5, proposal §7).

## Everyday use

```bash
minty-backup-status             # THE one to reach for — safe at any moment
minty-backup-status --watch     # redraw every 5s while something runs
minty-backup-status --json      # machine-readable
minty-backup-status --log       # follow the live log

minty-backup --preflight        # guards only — writes nothing, stamps nothing
minty-backup-check --status     # what verification task is due, and when
minty-backup-watch --status     # stamp ages, never alarms
minty-backup-watch --test       # prove the ntfy path works

# Anything under sudo needs the ABSOLUTE path — see the note below:
sudo /home/rafael/scripts/bin/minty-backup                    # a full run by hand
sudo /home/rafael/scripts/bin/minty-backup --preflight        # guards, as root
sudo /home/rafael/scripts/bin/minty-backup-check              # run whatever is due
sudo /home/rafael/scripts/bin/minty-backup-check --force-all  # incl. long self-test
```

**`sudo minty-backup` fails with `command not found`.** `sudo` replaces `PATH`
with the sudoers `secure_path`, which does not include `~/scripts/bin` — so the
bare name resolves for your shell but not for root's. Give sudo the absolute
path. The crontab lines below already do, so this bites only by-hand use; and it
fails loudly rather than silently, which is the right way round.

`--preflight` is the diagnostic to reach for first. It checks, in order: the
mount sentinel, root, borg's presence, and that `borg info` can open the repo.
With the drive unplugged it aborts on the first check and exits non-zero.

## Cron

**ARMED since 2026-08-04.** All three lines are installed and the nightly run
fires unattended.

**Verified in production:**

| Line | Proof |
|---|---|
| `0 23 * * *` backup | fired 2026-08-04 23:00:01, rc 0, green stamp, 5 m 50 s |
| `35 5 * * *` watcher | fired 2026-08-05 05:35:01 — "all anchors fresh" |
| ntfy alarm path | `minty-backup-watch --test` → "test alarm sent", push received |
| `0 7 * * 6` check | ✅ **installed** (confirmed in the root crontab 2026-08-05). Not yet *observed firing* — the first Saturday is 2026-08-08. If `STAMP.check` is still ~4 days old on 2026-08-09, that line did not run. |

Historically this was deliberately unarmed until the repo existed (tracker steps
1–3), because arming early makes the nightly run abort, never stamp, and the
watcher alarm every morning. See "the first-run trap" below.

```cron
# sudo crontab -e
0 23 * * *  /home/rafael/scripts/bin/minty-backup
0 7  * * 6  /home/rafael/scripts/bin/minty-backup-check

# crontab -e   (rafael)
35 5 * * *  /home/rafael/scripts/bin/minty-backup-watch
```

23:00 sits ahead of the org's fully-booked, docker-heavy 01:00–05:45 block.
05:35 sits between the org watcher (05:30) and forge-ci (05:45). Saturday 07:00
gives the ~10.7 h SMART long test room to finish well clear of the next backup.

## Quiescing the databases

Every container in `QUIESCE_CONTAINERS` is stopped for the borg phase and
restarted immediately after it. Configure it in `/etc/minty-backup.env`; empty
disables the whole mechanism.

**Why.** borg copies a live file as it finds it. An M/IRIS engine writing during
the copy produces an archive entry that is *not a valid database* — and borg
reports it as `file changed while we backed it up`, exiting rc=1. The 2026-08-04
first run hit this on `foia-iris`'s `IRIS.DAT`, its journal, and a live
`vehu.dat` inside a containerd snapshot. Stopping the engines is what makes the
copy a real point-in-time snapshot instead of a torn one.

**The restart is guaranteed, not best-effort.** `main()` installs
`trap 'quiesce_up || true' EXIT INT TERM` before stopping anything, so a borg
error, a `die()`, or a Ctrl-C still brings the engines back. Only containers that
this run actually stopped are restarted — one that was already down stays down.
All four abort paths are covered by tests.

**A failed restart alarms immediately** over ntfy rather than waiting for the
morning staleness check, which would never catch it: the stamp describes the
*backup*, and the backup succeeded. It is the one failure here that leaves the
machine worse off than if the run had never happened.

**The cost is a few minutes, not the 90 the first run took.** borg deduplicates,
so nightly incrementals re-read only changed blocks — proposal §4.2 puts them at
2–6 minutes. That is the real nightly downtime.

## Checking on it — `minty-backup-status`

Safe to run at any moment, including mid-backup, because **it never touches the
borg repo.** Everything comes from `/proc`, `df`, the stamps and the log — all
readable without sudo. That is a hard rule, not an optimisation: the one tool
that took the lock while another borg held it reported "silent bit-rot" about a
healthy repository.

Two things it deliberately does not do:

- **No percentage.** `/proc/<pid>/io` is root-only, so the running borg's byte
  counters cannot be read by an unprivileged observer. A real percent has to be
  *published by the runner* — status-proposal Tier 2, not built. What you get
  instead is true: elapsed, CPU-vs-wall (so an I/O-bound job is visibly waiting
  rather than stalled), and a repo growth rate sampled between invocations.
- **No verification.** It reports what the verifying jobs recorded. Running its
  own checks would be a second, unaudited verification path — needing the lock.

`--repo` is the one mode that runs borg, and it refuses (exit 3) if any borg
process is alive rather than queueing behind it.

The **VERDICT line names the weakest true claim**, not the happiest one. Green
runs with no `STAMP.check` reads `runs green, but VERIFICATION HAS NEVER
PASSED` — because "we write archives and have never proved we can read one back"
is the honest summary of that state.

## Arming: the first-run trap

Two things bite exactly once, when cron is armed but the verification calendar
has never run.

**An absent stamp is stale, not "not yet".** `minty-backup-watch` treats a
missing `STAMP.check` as a failure — correctly, since it cannot distinguish
"never ran" from "stopped running". But `minty-backup-check` is *weekly*, so
between arming and the first Saturday the watcher alarms every single morning.
Fix by running the check once by hand right after arming, not by waiting.

**Absent task stamps read as 99999 days, so the first check run does
everything** — including `smartctl -t long` (~10.7 h) and `borg check
--verify-data` (45–70 min). If a long self-test genuinely ran recently, record
that fact before the first run instead of repeating it:

```bash
sudo touch -d '<when the long test finished>' /var/lib/minty-backup/.task-smart-long
sudo /home/rafael/scripts/bin/minty-backup-check      # now skips the long test
```

That is recording history, not faking it — only do it when the test really ran.

## Gotchas

- **`borg extract` writes relative to the current directory** and borg stores
  paths without a leading slash. `cd /` for a full restore; `cd` to a staging
  directory for anything selective. Getting this wrong scatters a restore.
- **borg 1.2.x only.** Borg 2's repo format cannot read this repo without a
  `borg transfer` first. The version is recorded in every archive, in
  `/var/backups/minty-meta/versions.txt`.
- **The GRUB line is load-bearing.** Without
  `usb-storage.quirks=0bc2:2344:u`, a reboot returns the drive to the `uas`
  driver, SMART becomes unreadable, and the backup keeps stamping green over an
  unmonitored disk. `minty-backup-check` verifies this on every run and treats
  an unreadable SMART as **red**, never as a pass.
- **The sentinel is created by hand, once**, right after the ext4 format —
  never by a script, or it stops proving anything.
- **A borg warning is not a borg failure.** rc=0 is success, **rc=1 is a
  warning** over a complete archive, rc≥2 is an error. The original script
  treated any non-zero as failure, so the first run reported RED, skipped its
  stamp, and never reached `prune` — over a good 2.9 M-file archive. If you add
  another `borg` call here, route it through `borg_rc`.
- **`/var/lib/containerd` is excluded, like `/var/lib/docker`.** Both hold the
  same rebuildable engine state; excluding only the docker path missed the
  containerd store entirely. One copy of each engine is enough and that copy is
  the image archive in `~/data/vista-forge/images`, which *is* in the set.

## Logs

```
/var/log/minty-backup.log         nightly, self-trimmed to 20k lines
/var/log/minty-backup-check.log   weekly
~/data/minty-backup/watch.log     daily
```
