# rustdesk-status — Guide

## Purpose

RustDesk diagnostic and self-healing tool for **minty**. Provides a status
dashboard, comprehensive diagnostic check, rendezvous server port tests, live
log access, and fix actions — including resetting the `--server` exponential
backoff that causes the persistent "not ready" state.

## Design

A command-dispatch script: a single entry point with subcommands dispatched via a
`case` statement. Each command is an isolated `cmd_*` function that can be called
independently. Core state queries (`get_server_pid`, `rendezvous_connected`,
`rendezvous_server_up`, `proc_age_seconds`) are factored out as shared helpers
used by multiple commands.

The key diagnostic insight: RustDesk's `--server` process uses exponential
backoff after connection failures. Once the backoff interval grows large (can
reach hours), the process stops retrying even when the rendezvous server is
available. The fix is to kill only the `--server` child — the `--service` parent
respawns it within seconds with a fresh backoff state.

The `reset` command identifies the correct process by targeting user `rafael`
specifically (distinguishing the actual rustdesk binary from the root-owned `sudo`
wrapper that spawns it), checks the grace period, and kills only if a connection
is genuinely absent.

## Features

- Status dashboard: service state, all process PIDs, rendezvous connection
- Full diagnostic: 5 sections, pass/warn/fail counters
- Rendezvous server port tests (21115, 21116, 21117) with ICMP
- Recent journal lines + watchdog log entries
- Backoff reset: kills stuck `--server`, waits for respawn, confirms connection
- Full service restart (requires sudo)
- Watchdog log + timer state + fail counter
- Distinguishes three "not ready" causes: backoff, server outage, network failure
- Detects whether v2.2.0 watchdog (with `check_rustdesk`) is deployed

## Process Architecture

```
systemd
└── /usr/bin/rustdesk --service       (root)   service manager
    ├── sudo -u rafael … --server              spawns server
    │   └── /usr/share/rustdesk/rustdesk --server  (rafael)  rendezvous registration
    └── /usr/share/rustdesk/rustdesk --tray   (rafael)  system tray
```

RustDesk GUI (`rustdesk` with no flag) is spawned separately by the desktop session.
The `--server` process is the one that establishes and holds the TCP connection
to `rs-ny.rustdesk.com:21116`.

## Rendezvous Server Ports

| Port | Protocol | Service | Purpose |
|------|----------|---------|---------|
| 21115 | TCP | hbbs | NAT type test |
| 21116 | TCP + UDP | hbbs | Register, heartbeat, hole-punch |
| 21117 | TCP | hbbr | Relay (for when direct connection fails) |
| 21119 | UDP | local | WebSocket listener on this machine |

## "Not Ready" Cause Identification

| Symptom | `server` result | `reset` result | Meaning |
|---------|----------------|----------------|---------|
| No rendezvous conn, ports open | All open | Connects | `--server` was in backoff — fixed |
| No rendezvous conn, ports refused | All refused | No change | Public server outage |
| No rendezvous conn, ping fails | Ping fails | No change | Network failure |

## Functions

| Function | Description |
|---|---|
| `get_server_pid` | pgrep for the `--server` process owned by user `rafael` |
| `rendezvous_connected` | ss check for established TCP to `:21116` |
| `rendezvous_server_up` | nc TCP check to `rs-ny.rustdesk.com:21116` |
| `proc_age_seconds pid` | Seconds since process was created (via `/proc` stat mtime) |
| `human_age seconds` | Format seconds as `Xm Ys` or `Xh Ym` |
| `cmd_status` | Dashboard: service, processes, connection, watchdog |
| `cmd_check` | Full pass/warn/fail diagnostic |
| `cmd_server` | Port tests: ICMP + TCP 21115/21116/21117 |
| `cmd_logs [N]` | Journal + watchdog log tail |
| `cmd_reset` | Kill stuck `--server`, wait for respawn, confirm connection |
| `cmd_restart` | `sudo systemctl restart rustdesk` + connection wait |
| `cmd_watchdog [N]` | Watchdog log tail + timer + fail counter |
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
```

## Common Flow

RustDesk shows "not ready":
```bash
rustdesk-status.sh server   # is the public server up?
rustdesk-status.sh reset    # if yes — reset backoff
rustdesk-status.sh status   # confirm connection
```

## Integration with Watchdog

When `minty-network-watchdog.sh` v2.2.0+ is deployed, `check_rustdesk` runs every
5 minutes automatically:
- Skips if `rustdesk.service` is inactive
- Skips if `--server` is < 60 seconds old (grace period)
- Kills `--server` if no rendezvous connection after the grace period
- Never restarts `systemd-resolved` or the full rustdesk service
- Does not contribute to the reboot counter

## Files

| Path | Description |
|------|-------------|
| `~/.config/rustdesk/RustDesk2.toml` | Config: rendezvous server, NAT type |
| `~/.config/rustdesk/RustDesk.toml` | Key pair and encrypted password |
| `/tmp/RustDesk/ipc` | IPC socket between `--service` and `--server` |
| `/var/log/minty-network-watchdog.log` | Watchdog log (includes RustDesk fix events) |
