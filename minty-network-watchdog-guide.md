# minty-network-watchdog — Guide

## Purpose

Self-healing network watchdog for **minty** (Linux Mint 22.3). Runs every 5
minutes via a systemd timer, checks internet reachability, Tailscale connectivity,
SSH port, and RustDesk rendezvous registration. Attempts targeted service recovery
before escalating to a full system reboot. Works alongside the kernel hardware
watchdog as a complementary userspace layer.

## Design

Two independent recovery layers:

| Layer | Mechanism | Handles |
|---|---|---|
| **Service watchdog** | `minty-network-watchdog` (this tool) | Services stuck or crashed in a running kernel |
| **Kernel watchdog** | systemd `RuntimeWatchdogSec` | Kernel hang / systemd freeze |

The script uses a fail counter persisted to disk (`/var/lib/minty-network-watchdog/fail_count`).
Only consecutive failures of **critical** checks (internet or SSH) increment the
counter toward the reboot threshold. Tailscale and RustDesk are **soft
dependencies** — they trigger targeted recovery actions but never contribute to
a reboot.

The Tailscale check uses the `tailscale0` interface IP rather than parsing
`tailscale status` text, which can contain transient health warnings even when
Tailscale is fully operational. The IP check is a direct, false-positive-free test.

The two-step Tailscale fix (tailscaled only first, systemd-resolved only as a
step-2 escalation) prevents unnecessary DNS outages. RustDesk connects via the
LAN interface, not Tailscale, so restarting tailscaled alone never disrupts the
RustDesk rendezvous connection.

## Features

- Runs via systemd timer: 2-minute boot delay, then every 5 minutes
- **Internet check**: `ping -c 1 1.1.1.1`
- **Tailscale check**: interface IP on `tailscale0` (not text parsing)
- **SSH check**: TCP connect to `127.0.0.1:22`
- **RustDesk check**: detects `--server` stuck in exponential backoff; kills and respawns
- Tailscale fix: step 1 restarts `tailscaled` only; step 2 also restarts `systemd-resolved` if step 1 fails
- Reboot after 3 consecutive critical failures (internet + SSH)
- Boot guard: no reboot if uptime < 300s (prevents boot loops)
- Fail counter reset before reboot (prevents immediate reboot on next boot)
- Log rotation at 5 MB, keeps last 500 lines
- Optional `TS_AUTHKEY` via `/etc/minty-network-watchdog.env`

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 2.2.0 | 2026-04-13 | Added `check_rustdesk`: kills stuck `--server` to reset backoff |
| 2.1.0 | 2026-04-13 | `fix_tailscale`: two-step restart; `systemd-resolved` only as escalation |
| 2.0.0 | 2026-04-12 | Tailscale check via interface IP; reboot on internet/SSH only; boot guard 300s; fail counter reset before reboot |
| 1.0.0 | 2026-04-12 | Initial version |

## Check Logic

| Check | Method | Pass condition | On fail |
|---|---|---|---|
| Internet | `ping -c 1 -W 5 1.1.1.1` | Ping succeeds | Increment fail counter |
| Tailscale | `ip addr show tailscale0 \| grep 100\.` | Interface has 100.x address | Run `fix_tailscale` |
| SSH port | TCP connect `127.0.0.1:22` | Connection accepted | Increment fail counter |
| RustDesk | `ss -tn state established \| grep :21116` (after 60s grace) | Connection exists | Kill `--server` PID |

## Reboot Condition

Reboot is triggered only when:
- `internet_ok == 0` **OR** `ssh_ok == 0` (either critical check fails)
- This has happened **3 consecutive times** (fail counter ≥ 3)
- System uptime is ≥ 300 seconds (boot guard)

Tailscale and RustDesk failures alone **never** trigger a reboot.

## Functions

| Function | Description |
|---|---|
| `log level msg` | Timestamped log to file and stdout |
| `rotate_log` | Truncate log to last 500 lines when > 5 MB |
| `get/set/inc/reset_fail_count` | Fail counter persistence in `/var/lib/minty-network-watchdog/fail_count` |
| `uptime_seconds` | Read `/proc/uptime` and return integer seconds |
| `check_internet` | Ping 1.1.1.1 |
| `check_tailscale` | Three-part check: binary, daemon, interface IP |
| `check_ssh_port` | TCP connect to local port 22 |
| `check_rustdesk` | Detect stuck `--server` process and kill to reset backoff |
| `fix_tailscale` | Step 1: restart tailscaled; step 2: also restart systemd-resolved if still down |
| `nuclear_reboot reason` | Log state snapshot, reset fail counter, call `/sbin/reboot` |
| `main` | Orchestrates all checks, fix, and reboot decision |

## Files

| Path | Description |
|------|-------------|
| `/usr/local/sbin/minty-network-watchdog.sh` | Deployed script |
| `/etc/systemd/system/minty-network-watchdog.service` | Systemd oneshot service |
| `/etc/systemd/system/minty-network-watchdog.timer` | Systemd timer (every 5 min) |
| `/etc/minty-network-watchdog.env` | Optional env file (TS_AUTHKEY) |
| `/var/lib/minty-network-watchdog/fail_count` | Persistent fail counter |
| `/var/log/minty-network-watchdog.log` | Persistent log (5 MB rotating) |

## Use

```bash
# Deploy / update (from source directory)
cd ~/scripts/minty-network-watchdog
sudo bash install.sh

# Trigger an immediate check
sudo systemctl start minty-network-watchdog.service

# Watch live output
journalctl -fu minty-network-watchdog.service

# View persistent log
tail -f /var/log/minty-network-watchdog.log

# Check timer schedule
systemctl list-timers minty-network-watchdog.timer

# View fail counter
cat /var/lib/minty-network-watchdog/fail_count

# Reset fail counter
echo 0 | sudo tee /var/lib/minty-network-watchdog/fail_count
```

## Architecture note — two watchdog layers

The kernel hardware watchdog feeds `/dev/watchdog` via systemd. If systemd itself
stops responding for longer than `RuntimeWatchdogSec` (configured in
`/etc/systemd/system.conf`), the firmware resets the machine. This catches hard
hangs that no userspace script can detect. The two layers are complementary:
the service watchdog handles soft failures; the kernel watchdog handles hard hangs.
