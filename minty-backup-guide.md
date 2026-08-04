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
minty-backup --preflight        # guards only — writes nothing, stamps nothing
sudo minty-backup               # a full run by hand
minty-backup-check --status     # what verification task is due, and when
sudo minty-backup-check         # run whatever is due
sudo minty-backup-check --force-all   # everything, long self-test included
minty-backup-watch --status     # stamp ages, never alarms
minty-backup-watch --test       # prove the ntfy path works
```

`--preflight` is the diagnostic to reach for first. It checks, in order: the
mount sentinel, root, borg's presence, and that `borg info` can open the repo.
With the drive unplugged it aborts on the first check and exits non-zero.

## Cron

Not armed until the repo exists (tracker steps 1–3) — arming early means the
nightly run aborts, never stamps, and the watcher alarms every morning.

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

## Logs

```
/var/log/minty-backup.log         nightly, self-trimmed to 20k lines
/var/log/minty-backup-check.log   weekly
~/data/minty-backup/watch.log     daily
```
