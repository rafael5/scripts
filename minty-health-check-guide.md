# minty-health-check — Guide

## Purpose

Validate the full remote-access configuration of **minty** (Linux Mint 22.3) in a
single run. Covers SSH, Tailscale, RustDesk, sleep/suspend masking, auto-login,
service restart policies, NTP, swap, kernel panic recovery, GRUB timeout, and
Tailscale key expiry. Designed to be run after any significant system change or
reboot to confirm the machine will stay remotely accessible.

## Design

Fourteen independent check functions are called in sequence. Each function prints
`✔ pass`, `⚠ warn`, or `✘ fail` lines using shared helpers, and increments the
global `PASS`, `WARN`, or `FAIL` counters. A final summary prints totals and an
overall verdict.

No check function depends on the result of another — all sections run even if
earlier ones fail. This ensures a complete picture is always produced. Functions
that require sudo issue the sudo command inline; the user is prompted once if the
session lacks a cached credential.

Constants at the top of the script (`SSH_PORT`, `TAILSCALE_HOSTNAME`,
`SSH_ALIVE_INTERVAL_MIN`, etc.) are the only values that would need changing
for a different host.

## Features

- 14 check sections covering the full remote-access stack
- Coloured pass/warn/fail output with `·` info lines for context
- Summary table: pass/warn/fail counts and overall verdict
- All checks are independent — full report even when some fail
- No arguments — run as your normal user; sudo prompts appear as needed

## Check Sections

| # | Section | Key checks |
|---|---------|-----------|
| 1 | SSH | sshd active/enabled, port 22 accepting, ClientAliveInterval/CountMax, sshd -t syntax, authorized_keys perms |
| 2 | Firewall (UFW) | UFW active, port 22 exposure |
| 3 | Tailscale | Binary, daemon, network node status, IPv4 address, systemd override for `network-online.target`, NM-wait-online enabled |
| 4 | RustDesk | Binary, service active/enabled, system unit path, virtual display |
| 5 | Sleep/Suspend | All four sleep targets masked |
| 6 | Auto-login | LightDM autologin-user set |
| 7 | Restart Policies | tailscaled, rustdesk, ssh all have non-`no` restart policy |
| 8 | NTP | timedatectl NTP active, clock synchronized |
| 9 | Swap | Swap present (prevents OOM killing daemons) |
| 10 | Kernel Panic | `kernel.panic > 0`, `kernel.panic_on_oops = 1` |
| 11 | GRUB Timeout | `GRUB_TIMEOUT` ≤ 10 (auto-boots, no remote boot blockage) |
| 12 | Tailscale Key Expiry | Key not expired, warns if expiry within 14 days |
| 13 | System Health | Disk space, failed systemd units, internet reachability, uptime |

## Functions

| Function | Description |
|---|---|
| `pass/warn/fail/info` | Coloured output + counter increment |
| `section` | Bold section header |
| `has_cmd cmd` | Returns 0 if command is in PATH |
| `svc_enabled svc` | Returns 0 if systemd unit is enabled |
| `svc_active svc` | Returns 0 if systemd unit is active |
| `check_ssh` | SSH section (6 checks) |
| `check_firewall` | UFW section |
| `check_tailscale` | Tailscale section (6 checks) |
| `check_rustdesk` | RustDesk section (4 checks) |
| `check_sleep` | Sleep masking section (4 checks) |
| `check_autologin` | LightDM auto-login section |
| `check_restart_policies` | Service restart policy section |
| `check_ntp` | NTP section |
| `check_swap` | Swap section |
| `check_kernel_panic` | Kernel panic section |
| `check_grub` | GRUB timeout section |
| `check_tailscale_expiry` | Tailscale key expiry section |
| `check_system` | System health section |
| `print_summary` | Totals and overall verdict |

## Use

```bash
# Run as your normal user
minty-health-check.sh
```

Requires sudo for: `ufw status`, `sshd -t`. These are issued inline; you may be
prompted once for your password if the session cache has expired.

## Output

| Symbol | Meaning |
|--------|---------|
| `✔` green | Pass — no action needed |
| `⚠` yellow | Warn — degraded or suboptimal but not broken |
| `✘` red | Fail — action required |
| `·` cyan | Info — contextual detail |

## Dependencies

All checks use tools pre-installed on Linux Mint 22.3 or part of the remote-access
stack being validated (`tailscale`, `rustdesk`).
