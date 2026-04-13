# minty-network-watchdog install — Guide

## Purpose

Deploy the `minty-network-watchdog` system to `/usr/local/sbin/` and register it
as a systemd timer that runs every 5 minutes. Must be run as root. Idempotent —
safe to re-run when deploying updates to the watchdog script or service units.

## Design

A simple root-only installer. All files are deployed using `install` with explicit
permissions rather than `cp`, ensuring correct ownership and mode in a single
command. The optional environment file (`/etc/minty-network-watchdog.env`) is
created only if absent, so an existing `TS_AUTHKEY` configuration is never
overwritten.

The installer always re-enables and starts the timer, so running it after updating
`minty-network-watchdog.sh` immediately activates the new version — there is no
separate "reload" step needed.

## Features

- Deploys watchdog script to `/usr/local/sbin/` with mode 750 (root-executable only)
- Deploys systemd service and timer units to `/etc/systemd/system/`
- Creates `/etc/minty-network-watchdog.env` only if absent (preserves TS_AUTHKEY)
- Creates `/var/lib/minty-network-watchdog/` state directory
- Runs `systemctl daemon-reload` + `enable --now` the timer
- Coloured pass/warn/fail output
- Aborts if not run as root

## Functions

| Function | Description |
|---|---|
| `ok msg` | Print green ✔ confirmation |
| `warn msg` | Print yellow ⚠ warning |
| `die msg` | Print red ✘ error and exit 1 |

## Files Deployed

| Source | Destination | Mode |
|--------|------------|------|
| `minty-network-watchdog.sh` | `/usr/local/sbin/minty-network-watchdog.sh` | 750 |
| `minty-network-watchdog.service` | `/etc/systemd/system/minty-network-watchdog.service` | 644 |
| `minty-network-watchdog.timer` | `/etc/systemd/system/minty-network-watchdog.timer` | 644 |
| *(generated)* | `/etc/minty-network-watchdog.env` | 640 |
| *(directory)* | `/var/lib/minty-network-watchdog/` | — |

## Use

```bash
# Run from the minty-network-watchdog source directory
cd ~/scripts/minty-network-watchdog
sudo bash install.sh
```

After installation:
```bash
# Verify timer is running
systemctl list-timers minty-network-watchdog.timer

# Trigger an immediate check
sudo systemctl start minty-network-watchdog.service

# Watch live log output
journalctl -fu minty-network-watchdog.service

# Persistent log
tail -f /var/log/minty-network-watchdog.log
```

## To Configure TS_AUTHKEY (Optional)

If Tailscale requires headless re-authentication, add the auth key to the env file:

```bash
sudo nano /etc/minty-network-watchdog.env
# Uncomment and set:
# TS_AUTHKEY=tskey-auth-...
```

## Notes

- Re-run `sudo bash install.sh` after any change to `minty-network-watchdog.sh`
  to deploy the update
- The timer is activated immediately after install — no reboot needed
- The fail counter at `/var/lib/minty-network-watchdog/fail_count` is preserved
  across installs; reset it manually with `echo 0 | sudo tee /var/lib/minty-network-watchdog/fail_count`
  if needed
