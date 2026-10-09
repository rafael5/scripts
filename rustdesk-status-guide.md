# rustdesk-status — Guide

## Purpose

RustDesk diagnostic and self-healing tool for **minty**. Provides a status
dashboard, comprehensive diagnostic check, rendezvous server port tests, live
log access, and fix actions — including resetting the `--server` exponential
backoff that causes the persistent "not ready" state.

Since 2026-09-30 clients connect to minty by its tailnet address, through
RustDesk's direct IP access on port 21118, so the public rendezvous server is
no longer needed to reach it. The direct-access checks decide whether minty is
reachable; rendezvous problems are warnings, for connections by RustDesk ID
only. To connect, type minty's tailnet IP (`tailscale ip -4`) in the RustDesk
client's ID box.

## Design

A command-dispatch script: a single entry point with subcommands dispatched via a
`case` statement. Each command is an isolated `cmd_*` function that can be called
independently. Core state queries (`get_server_pid`, `rendezvous_connected`,
`rendezvous_server_up`, the `direct_*` checks, `proc_age_seconds`) are factored out as shared helpers
used by multiple commands.

The key diagnostic insight: RustDesk's `--server` process uses exponential
backoff after connection failures. Once the backoff interval grows large (can
reach hours), the process stops retrying even when the rendezvous server is
available. The fix is to kill only the `--server` child — the `--service` parent
respawns it within seconds with a fresh backoff state.

The `reset` command identifies the correct process by targeting user `rafael`
specifically (distinguishing the actual rustdesk binary from the root-owned `sudo`
wrapper that spawns it), checks the grace period, and kills only if a connection
is genuinely absent. Killing `--server` ends every session it holds, so `reset`
refuses while a session is established on the direct-access port.

## Features

- Status dashboard: one line each for service, processes, direct access,
  rendezvous and watchdog; a fix hint only under a line that is not green
- Full diagnostic: one line per area, pass/warn/fail counted per sub-check,
  a fix hint only under a line that is not green
- Direct access: option on, listening on 21118, answering on the tailnet
  address (tested from this host, so the firewall is not tested), live
  session count
- Rendezvous server port tests (21115, 21116, 21117) with ICMP, on one line
- Recent journal lines + watchdog log entries
- Backoff reset: kills stuck `--server`, waits for respawn, confirms connection;
  refused while a session is live on 21118
- Full service restart (requires sudo)
- Watchdog: timer + fail counter, then the last N runs (default 10), one
  line each; a run with a failure or fix action lists those lines beneath it
- Distinguishes three "not ready" causes: backoff, server outage, network failure
- Detects whether a watchdog with `check_rustdesk` (v2.2.0+) is deployed

## Process Architecture

```
systemd
└── /usr/bin/rustdesk --service       (root)   service manager
    ├── sudo -u rafael … --server              spawns server
    │   └── /usr/share/rustdesk/rustdesk --server  (rafael)  rendezvous registration
    └── /usr/share/rustdesk/rustdesk --tray   (rafael)  system tray
```

RustDesk GUI (`rustdesk` with no flag) is spawned separately by the desktop session.
The `--server` process registers with `rs-ny.rustdesk.com:21116` over UDP and
listens on port 21118 for direct connections from the tailnet.

## Ports

| Port | Protocol | Service | Purpose |
|------|----------|---------|---------|
| 21115 | TCP | hbbs | NAT type test |
| 21116 | TCP + UDP | hbbs | Register, heartbeat, hole-punch |
| 21117 | TCP | hbbr | Relay (for when direct connection fails) |
| 21118 | TCP | local | Direct IP access on this machine — how tailnet clients connect |
| 21119 | UDP | local | WebSocket listener on this machine |

## "Not Ready" Cause Identification  (ID connections only)

| Symptom | `server` result | `reset` result | Meaning |
|---------|----------------|----------------|---------|
| No rendezvous conn, ports open | All open | Connects | `--server` was in backoff — fixed |
| No rendezvous conn, ports refused | All refused | No change | Public server outage |
| No rendezvous conn, ping fails | Ping fails | No change | Network failure |

## Functions

| Function | Description |
|---|---|
| `get_server_pid` | pgrep for the `--server` process owned by user `rafael` |
| `rendezvous_connected` | A `Latency of rs-ny…:21116` line in the `--server` log within 120 s |
| `rendezvous_server_up` | nc TCP check to `rs-ny.rustdesk.com:21116` |
| `direct_access_enabled` | `direct-server = 'Y'` in the RustDesk config |
| `direct_port_listening` | `ss` finds a listener on the direct-access port |
| `direct_port_reachable` | nc TCP check to the tailnet address and direct-access port |
| `direct_sessions` | Count of established sessions on the direct-access port |
| `tailnet_ip` | This host's Tailscale IPv4 address |
| `proc_age_seconds pid` | Seconds since the process started, from the kernel's start time (`ps -o etimes=`); 0 if it is gone |
| `human_age seconds` | Format seconds as `Xm Ys` or `Xh Ym` |
| `cmd_status` | Dashboard: service, processes, connection, watchdog |
| `cmd_check` | Full pass/warn/fail diagnostic |
| `cmd_server` | Port tests: ICMP + TCP 21115/21116/21117 |
| `cmd_logs [N]` | Journal + watchdog log tail |
| `cmd_reset` | Kill stuck `--server`, wait for respawn, confirm connection |
| `cmd_restart` | `sudo systemctl restart rustdesk` + connection wait |
| `cmd_watchdog [N]` | Timer + fail counter, last N runs one line each |
| `cmd_help` | Usage and flow documentation |

## Use

```bash
# Status dashboard (default)
rustdesk-status.sh

# Full diagnostic
rustdesk-status.sh check

# Test rendezvous server ports
rustdesk-status.sh server

# Reset stuck --server backoff (most common fix)
rustdesk-status.sh reset

# Show recent logs
rustdesk-status.sh logs
rustdesk-status.sh logs 50

# Watchdog state
rustdesk-status.sh watchdog

# Full service restart (requires sudo)
rustdesk-status.sh restart

# Check another direct-access port (default 21118)
RUSTDESK_DIRECT_PORT=21119 rustdesk-status.sh check
```

## Common Flow

Can't connect by tailnet address:
```bash
rustdesk-status.sh status   # is Direct Access green?
```

Connecting by RustDesk ID, and it shows "not ready":
```bash
rustdesk-status.sh server   # is the public server up?
rustdesk-status.sh reset    # if yes — reset backoff
rustdesk-status.sh status   # confirm connection
```

## Integration with Watchdog

When `minty-network-watchdog.sh` v2.3.0+ is deployed, `check_rustdesk` runs every
5 minutes automatically:
- Skips if `rustdesk.service` is inactive
- Skips if `--server` is < 60 seconds old (grace period)
- Kills `--server` if nothing listens on port 21118 after the grace period and
  direct IP access is on; with the option off it only logs a warning
- Does not check the public rendezvous server
- Never restarts `systemd-resolved` or the full rustdesk service
- Does not contribute to the reboot counter

## Files

| Path | Description |
|------|-------------|
| `~/.config/rustdesk/RustDesk2.toml` | Config: rendezvous server, NAT type, `direct-server` option. The root `--service` holds the options and rewrites this file, so set an option with `sudo rustdesk --option <key> <value>`, never by editing it |
| `~/.config/rustdesk/RustDesk.toml` | Key pair and encrypted password |
| `/tmp/RustDesk/ipc` | IPC socket between `--service` and `--server` |
| `/var/log/minty-network-watchdog.log` | Watchdog log (includes RustDesk fix events) |
