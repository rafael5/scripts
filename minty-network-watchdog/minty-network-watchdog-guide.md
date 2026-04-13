# minty-network-watchdog — Guide

A self-healing network watchdog for **minty** (Linux Mint 22.3 "Zena", x86_64).
Runs every 5 minutes via a systemd timer. Attempts targeted service recovery
before falling back to a full system reboot. Works alongside the kernel hardware
watchdog (systemd `RuntimeWatchdogSec`) as a complementary layer.

## Architecture

Two independent layers handle different failure modes:

| Layer | Mechanism | Handles |
|---|---|---|
| **Service watchdog** | `minty-network-watchdog` (this tool) | Services stuck/crashed in a running kernel |
| **Kernel watchdog** | systemd `RuntimeWatchdogSec` in `/etc/systemd/system.conf` | Kernel hang / systemd freeze |

The kernel watchdog feeds `/dev/watchdog` via systemd. If systemd itself stops
responding for longer than `RuntimeWatchdogSec`, the firmware resets the machine.
This catches hard hangs that no userspace script can detect.

## What it checks

| Check | Method | Pass condition | Triggers reboot? |
|---|---|---|---|
| Internet | `ping -c 1 1.1.1.1` | Cloudflare DNS reachable | Yes (critical) |
| SSH port | TCP connect to `127.0.0.1:22` | Port accepting connections | Yes (critical) |
| Tailscale | `ip addr show dev tailscale0` | Interface has a `100.x.x.x` address | No (recovery only) |

**Tailscale is a soft dependency.** It failing alone never triggers a reboot —
only service recovery. Reboot is reserved for true inaccessibility (no internet
or no SSH).

### Why the Tailscale check uses the interface address

`tailscale status` output includes a `# Health check:` section that reports
transient DNS warnings even when Tailscale is fully connected and DNS works.
Parsing that text produces false positives. Checking whether `tailscale0` has a
`100.x.x.x` IP is a direct, text-parsing-free test: the interface exists and
holds its address if and only if Tailscale is connected.

## Recovery actions

### Tailscale down

1. Restart `systemd-resolved` **and** `tailscaled` together.
   - Reason: a stale DNS config on the `tailscale0` interface can leave
     `systemd-resolved` broken even after `tailscaled` restarts alone. Both
     must restart to clear it.
2. Wait `TAILSCALE_RESTART_WAIT` seconds (default 15).
3. Run `tailscale up` (or `tailscale up --authkey <key> --reset` if
   `TS_AUTHKEY` is set in the env file).
4. Recheck. Log the result. The fail counter is **not** incremented for
   Tailscale-only failures.

### Internet or SSH down

1. Increment the consecutive-failure counter
   (`/var/lib/minty-network-watchdog/fail_count`).
2. If counter < `MAX_FAILS`: log and wait for the next timer interval.
3. If counter ≥ `MAX_FAILS`: log diagnostics and call `systemctl reboot`.

The counter resets to 0 whenever all critical checks pass, and also immediately
before any reboot (to prevent a boot loop if the fault persists after restart).

### Boot-storm guard

Reboots are skipped if system uptime < `UPTIME_REBOOT_GUARD` (default 300 s).
This prevents the watchdog from rebooting a machine that is still in the middle
of its own startup sequence.

## Files

| Path | Purpose |
|---|---|
| `minty-network-watchdog.sh` | Main watchdog script (source) |
| `minty-network-watchdog.service` | systemd one-shot service unit |
| `minty-network-watchdog.timer` | systemd timer (every 5 min, 2 min after boot) |
| `install.sh` | Installer — run as root from this directory |

After installation, the live script is at `/usr/local/sbin/minty-network-watchdog.sh`.

## Installation

```bash
cd ~/scripts/minty-network-watchdog
sudo bash install.sh
```

The installer:
- Deploys the script to `/usr/local/sbin/` (mode 750, owned root:root)
- Installs the systemd service and timer units to `/etc/systemd/system/`
- Creates `/etc/minty-network-watchdog.env` (optional config, not overwritten if
  it already exists)
- Creates state dir `/var/lib/minty-network-watchdog/`
- Runs `systemctl daemon-reload` and enables + starts the timer

### Re-deploying after script changes

```bash
cd ~/scripts/minty-network-watchdog
sudo bash install.sh   # idempotent — safe to run again
```

## Kernel hardware watchdog (complementary)

This must be configured separately. Add to `/etc/systemd/system.conf`:

```ini
RuntimeWatchdogSec=20s
RebootWatchdogSec=10min
```

Then reload systemd:

```bash
sudo systemctl daemon-reload
```

`RuntimeWatchdogSec=20s` — systemd feeds `/dev/watchdog` every 20 seconds.
If systemd stops (kernel panic, hard hang), the firmware resets the machine.
`RebootWatchdogSec=10min` — if a `systemctl reboot` doesn't complete within
10 minutes, the hardware watchdog forces a reset.

Verify it is active:

```bash
sudo cat /sys/class/watchdog/watchdog0/status   # should show "no timeout" or similar
journalctl -b -k | grep -i watchdog             # kernel watchdog init messages
```

## Optional: Tailscale auth key

For headless re-authentication when the Tailscale node has been logged out:

```bash
sudo nano /etc/minty-network-watchdog.env
```

Uncomment and set:

```bash
TS_AUTHKEY=tskey-auth-...
```

When `TS_AUTHKEY` is set, the fix step runs:

```bash
tailscale up --authkey "$TS_AUTHKEY" --reset
```

instead of a plain `tailscale up`. The auth key is read from the env file at
runtime; it is never stored in the script itself.

## Logs

The watchdog writes to two destinations simultaneously:

| Destination | View with |
|---|---|
| `/var/log/minty-network-watchdog.log` | `tail -f /var/log/minty-network-watchdog.log` |
| systemd journal | `journalctl -fu minty-network-watchdog.service` |

Log levels: `INFO`, `WARN`, `FIX`, `CRITICAL`.

The log file self-rotates when it exceeds `MAX_LOG_SIZE_KB` (default 5 MB),
retaining the last `MAX_LOG_LINES_KEEP` lines (default 500).

### Sample log — Tailscale recovery (no reboot)

```
2026-04-12 22:42:58 [INFO] === Network watchdog run start ===
2026-04-12 22:42:58 [INFO] Internet: OK (1.1.1.1 reachable)
2026-04-12 22:42:58 [WARN] Tailscale: FAIL (tailscale0 has no 100.x address)
2026-04-12 22:42:58 [INFO] SSH port 22: OK
2026-04-12 22:42:58 [FIX] Tailscale check failed — attempting restart
2026-04-12 22:42:58 [FIX] Restarting systemd-resolved and tailscaled...
2026-04-12 22:43:13 [FIX] Running: tailscale up
2026-04-12 22:43:14 [INFO] Tailscale recovered (100.117.23.46/32)
2026-04-12 22:43:14 [INFO] All critical checks passed — resetting fail counter
2026-04-12 22:43:14 [INFO] === Network watchdog run complete ===
```

### Sample log — reboot triggered (internet + SSH lost)

```
2026-04-12 23:10:01 [WARN] Internet: FAIL (1.1.1.1 unreachable)
2026-04-12 23:10:01 [WARN] SSH port 22: FAIL (not accepting connections)
2026-04-12 23:10:01 [WARN] Critical check(s) failed — consecutive fail count: 3/3
2026-04-12 23:10:01 [CRITICAL] === REBOOT INITIATED ===
2026-04-12 23:10:01 [CRITICAL] Reason: Network checks failed 3 consecutive times (internet=0 tailscale=1 ssh=0)
2026-04-12 23:10:01 [CRITICAL] Uptime: 3625s
2026-04-12 23:10:01 [CRITICAL] Rebooting now...
```

## Useful commands

```bash
# Show when the timer next fires
systemctl list-timers minty-network-watchdog.timer

# Run a check immediately (outside the timer)
sudo systemctl start minty-network-watchdog.service

# Watch a live run in real time
journalctl -fu minty-network-watchdog.service

# Tail the persistent log
tail -f /var/log/minty-network-watchdog.log

# Inspect the consecutive-failure counter
cat /var/lib/minty-network-watchdog/fail_count

# Reset the failure counter manually (e.g. after resolving a known issue)
echo 0 | sudo tee /var/lib/minty-network-watchdog/fail_count

# Stop the watchdog temporarily (survives until next boot)
sudo systemctl stop minty-network-watchdog.timer

# Disable the watchdog permanently
sudo systemctl disable --now minty-network-watchdog.timer

# Re-enable after disabling
sudo systemctl enable --now minty-network-watchdog.timer
```

## Tuning constants

All thresholds are defined with `readonly` at the top of
`minty-network-watchdog.sh`. Edit the source file and re-run `install.sh` to
deploy changes.

| Constant | Default | Meaning |
|---|---|---|
| `INTERNET_HOST` | `1.1.1.1` | Ping target for internet check |
| `INTERNET_TIMEOUT` | 5 s | Ping wait timeout |
| `SSH_PORT` | 22 | Port to probe for SSH liveness |
| `SSH_TIMEOUT` | 3 s | TCP connect timeout |
| `TAILSCALE_RESTART_WAIT` | 15 s | Settle time after restarting tailscaled + resolved |
| `UPTIME_REBOOT_GUARD` | 300 s | Minimum uptime before a reboot is allowed |
| `MAX_FAILS` | 3 | Consecutive critical failures before reboot |
| `MAX_LOG_SIZE_KB` | 5120 | Log rotation threshold (5 MB) |
| `MAX_LOG_LINES_KEEP` | 500 | Lines retained after rotation |

## Script internals

### Functions

| Function | Purpose |
|---|---|
| `log level msg` | Write timestamped entry to log file and stdout (→ journal) |
| `rotate_log` | Trim log file to `MAX_LOG_LINES_KEEP` if over `MAX_LOG_SIZE_KB` |
| `get_fail_count` | Read current counter from state file (returns 0 if missing) |
| `set_fail_count n` | Write counter to state file, creating state dir if needed |
| `inc_fail_count` | Increment counter and echo new value |
| `reset_fail_count` | Write 0 to counter file |
| `uptime_seconds` | Return system uptime in integer seconds via `/proc/uptime` |
| `check_internet` | Ping `INTERNET_HOST`; return 0/1 |
| `check_tailscale` | Check binary, daemon, and `tailscale0` interface IP; return 0/1 |
| `check_ssh_port` | TCP connect to `127.0.0.1:SSH_PORT`; return 0/1 |
| `fix_tailscale` | Restart `systemd-resolved` + `tailscaled`, then run `tailscale up` |
| `nuclear_reboot reason` | Log diagnostics, reset counter, call `systemctl reboot` |
| `main` | Orchestrates all checks, fix, and reboot decision |

### State file

`/var/lib/minty-network-watchdog/fail_count` — plain integer, one per line.
Persists across reboots. Reset to 0 automatically when:
- All critical checks pass, or
- A reboot is triggered (prevents boot loop if fault persists after restart)

### Execution flow

```
rotate_log
check_internet  → internet_ok
check_tailscale → tailscale_ok
check_ssh_port  → ssh_ok

if tailscale_ok == 0:
    fix_tailscale
    check_tailscale again → update tailscale_ok

if internet_ok == 1 AND ssh_ok == 1:
    reset_fail_count
else:
    inc_fail_count → fails
    if fails >= MAX_FAILS:
        if uptime < UPTIME_REBOOT_GUARD: skip reboot, reset counter
        else: nuclear_reboot
```

## Changelog

| Version | Date | Changes |
|---|---|---|
| 2.0.0 | 2026-04-12 | Tailscale check: interface IP instead of status text parsing; fix: also restart `systemd-resolved`; reboot condition: internet/SSH only; boot guard: 120 s → 300 s; fix: reset counter before reboot |
| 1.0.0 | 2026-04-12 | Initial version |
