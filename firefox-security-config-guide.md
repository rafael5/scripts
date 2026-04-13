# firefox-security-config — Guide

## Purpose

Apply a standard set of privacy and security hardening preferences to Firefox by
writing a `user.js` file directly into the active Firefox profile. Designed for
a personal Linux workstation where stronger defaults than Firefox ships with are
preferred.

## Design

Firefox's `user.js` is loaded at every browser start and locks preference values
regardless of what the GUI shows. This script auto-detects the active profile
directory (`.default-release`, falling back to `.default`) and writes the file in
a single pass using a heredoc. No external dependencies are needed — just bash and
an existing Firefox installation.

The script is intentionally simple: a `bash -c '...'` invocation that can be
pasted into a terminal or run as-is. No idempotency guard is needed because
`user.js` is rewritten completely on every run.

## Features

- Auto-detects Firefox profile (`*.default-release` first, then `*.default`)
- Creates the profile directory if it does not exist
- Writes 14 `user_pref()` entries covering six protection areas
- No external dependencies — standard bash only
- Idempotent: re-running overwrites cleanly

## Functions

The script is a single `bash -c` block with no named functions:

| Step | What it does |
|------|-------------|
| Profile detection | `find ~/.mozilla/firefox` for `.default-release` or `.default` |
| Directory guard | `mkdir -p "$PROFILE"` |
| user.js write | `cat > "$PROFILE/user.js"` with hardcoded heredoc |
| Confirmation | Echoes the profile path that was modified |

## Preference Reference

| Preference | Category | Effect |
|---|---|---|
| `privacy.resistFingerprinting` | Fingerprinting | Randomises browser fingerprint |
| `privacy.firstparty.isolate` | Tracking | Isolates cookies per top-level domain |
| `privacy.trackingprotection.enabled` | Tracking | Blocks known trackers |
| `network.cookie.cookieBehavior = 5` | Cookies | Rejects third-party cookies |
| `media.peerconnection.enabled = false` | WebRTC | Prevents IP leak via WebRTC |
| `geo.enabled = false` | Geolocation | Blocks location API |
| `dom.battery.enabled = false` | Fingerprinting | Disables battery status API |
| `browser.send_pings = false` | Privacy | Disables hyperlink auditing |
| `network.dns.disablePrefetch = true` | Privacy | Stops speculative DNS lookups |
| `dom.security.https_only_mode = true` | Security | Blocks plain HTTP connections |
| `datareporting.healthreport.uploadEnabled` | Telemetry | Stops health report uploads |
| `toolkit.telemetry.enabled/unified` | Telemetry | Disables crash/usage telemetry |
| `network.trr.mode = 2` | DNS | Enables DNS-over-HTTPS with fallback |
| `network.trr.uri` | DNS | Uses Cloudflare DoH endpoint |

## Use

```bash
# Run directly (file must be executable or called via bash)
bash firefox-security-config.sh

# Or paste the inner bash -c '...' block into any terminal
```

Requires Firefox to be installed and to have been opened at least once (so the
profile directory exists under `~/.mozilla/firefox/`).

**Effect is applied on next Firefox restart.** Existing `user.js` is fully replaced.

## Dependencies

- `bash` 4+
- Firefox with a profile directory under `~/.mozilla/firefox/`
