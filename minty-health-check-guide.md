# minty-health-check.sh — Guide

Health check script for reliable 24/7 remote access to **minty**
(Linux Mint, Tailscale + SSH + RustDesk stack).

## Usage

```bash
minty-health-check.sh
```

Requires sudo for a few checks (UFW status, sshd -t). Run as your normal user — sudo prompts appear automatically.

A one-line reminder is shown on every SSH login via `/etc/update-motd.d/99-health-check`.

## Output

Each check prints one of:

| Symbol | Meaning |
|--------|---------|
| ✔ green | Pass — no action needed |
| ⚠ yellow | Warn — degraded but not broken |
| ✘ red | Fail — action required |
| · cyan | Info — contextual detail |

The summary line at the end shows total pass/warn/fail counts and an overall verdict.

---

## Checks

### 1. SSH

**Why:** SSH over Tailscale is the primary remote terminal access path. If sshd is down or misconfigured after a reboot, you lose shell access.

| Check | What it verifies |
|-------|-----------------|
| sshd active | `systemctl is-active ssh` — service is running |
| sshd enabled | `systemctl is-enabled ssh` — survives reboot |
| Port 22 accepting | TCP connection to `127.0.0.1:22` succeeds locally |
| ClientAliveInterval | ≥ 30s in `/etc/ssh/sshd_config` — server sends keepalives to detect dead connections |
| ClientAliveCountMax | ≥ 3 in `/etc/ssh/sshd_config` — tolerates up to 3 missed keepalives before dropping |
| sshd_config syntax | `sudo sshd -t` — catches config errors before they cause a lockout on reboot |
| authorized_keys perms | `~/.ssh/authorized_keys` must be `600` or `400` — sshd ignores the file if world-readable |

**Fix keepalives** (`/etc/ssh/sshd_config`):
```
ClientAliveInterval 60
ClientAliveCountMax 10
```
Then: `sudo systemctl restart ssh`

---

### 2. Firewall (UFW)

**Why:** UFW provides defense-in-depth. Since SSH access is via Tailscale (private network), port 22 should *not* be exposed publicly — an open port 22 is unnecessary attack surface even with key-only auth.

| Check | What it verifies |
|-------|-----------------|
| UFW active | `ufw status` shows `Status: active` |
| Port 22 not public | Port 22 is absent from UFW rules — correct for Tailscale-only access |

**Note:** If port 22 appears in UFW rules, the check warns (not fails) — it's not broken, just unnecessary exposure.

---

### 3. Tailscale

**Why:** Tailscale is the private network tunnel that makes SSH and remote desktop reachable without exposing anything to the public internet. If Tailscale goes down after a reboot, both SSH and RustDesk become unreachable.

| Check | What it verifies |
|-------|-----------------|
| Binary present | `tailscale` found in PATH |
| tailscaled active | Daemon service is running |
| tailscaled enabled | Survives reboot |
| Node is up | `tailscale status` shows minty connected as `minty.warg-torino.ts.net` |
| Tailscale IPv4 | `tailscale ip -4` returns an address (confirms active tunnel) |
| systemd override | `/etc/systemd/system/tailscaled.service.d/override.conf` contains `network-online.target` — ensures Tailscale waits for the network before starting |
| NetworkManager-wait-online | Enabled — ensures NetworkManager signals network readiness before dependent services start |

**Fix network ordering** (if override missing):
```bash
sudo systemctl edit tailscaled
# Add:
[Unit]
After=network-online.target
Wants=network-online.target
```

---

### 4. RustDesk

**Why:** RustDesk provides remote desktop (GUI) access — the fallback when SSH isn't enough. Must run as a *system* service (not user session) so it starts before login. Needs a live desktop session to show a screen.

| Check | What it verifies |
|-------|-----------------|
| Binary present | `rustdesk` found in PATH |
| rustdesk active | Service is running |
| rustdesk enabled | Survives reboot |
| System service | Unit file path is under `/etc/systemd/system/`, `/lib/systemd/system/`, or `/usr/lib/systemd/system/` — not a user session unit |
| Virtual display | `$DISPLAY` is set or `Xvfb`/`xvfb-run` is available — prevents black screen on headless systems |

**Fix black screen** (if no display):
```bash
sudo apt install xvfb
```

---

### 5. Sleep / Suspend Resilience

**Why:** Linux Mint may sleep or suspend the desktop after inactivity. A sleeping machine drops all network connections and becomes unreachable remotely.

| Check | What it verifies |
|-------|-----------------|
| sleep.target masked | System cannot enter sleep |
| suspend.target masked | System cannot suspend |
| hibernate.target masked | System cannot hibernate |
| hybrid-sleep.target masked | System cannot hybrid-sleep |

**Fix** (if any target is unmasked):
```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

---

### 6. System Health

**Why:** Silent system problems — full disk, failed services, no internet — can make remote access fail in non-obvious ways.

| Check | What it verifies |
|-------|-----------------|
| Disk space | `/` and `/home` usage: warn at 85%, fail at 95% |
| Failed systemd units | `systemctl list-units --state=failed` (excludes `casper-md5check` — harmless Live ISO leftover) |
| Internet reachability | `ping 8.8.8.8` — confirms outbound connectivity for Tailscale relay and re-auth |
| Uptime / last boot | Warns if uptime < 10 minutes — may indicate an unexpected reboot |

---

### 7. Auto-login (Desktop Session)

**Why:** RustDesk needs a live desktop session to show a screen. If LightDM requires a password after reboot, RustDesk connects but shows a black screen — you're locked out of GUI access until someone physically logs in.

| Check | What it verifies |
|-------|-----------------|
| autologin-user set | `autologin-user=` in `/etc/lightdm/lightdm.conf` under `[Seat:*]` |

**Fix** (`/etc/lightdm/lightdm.conf`):
```ini
[Seat:*]
autologin-user=rafael
autologin-user-timeout=0
```

---

### 8. Service Restart Policies

**Why:** If a remote-access service crashes, it must restart automatically. Without a restart policy, a crashed tailscaled or rustdesk stays down until you can manually restart it — which you can't do if it's your only access path.

| Check | What it verifies |
|-------|-----------------|
| tailscaled Restart | `on-failure`, `always`, or `on-abnormal` |
| rustdesk Restart | Same — RustDesk ships with `Restart=no` by default; requires a systemd override |
| ssh Restart | Same |

**Fix rustdesk** (via systemd override — do not edit the package unit directly):
```bash
sudo systemctl edit rustdesk
# Add:
[Service]
Restart=on-failure
RestartSec=5
```
Then: `sudo systemctl daemon-reload`

---

### 9. Time Sync (NTP)

**Why:** Tailscale authentication and TLS certificates require an accurate system clock. Clock drift of more than a few minutes can cause Tailscale to fail reconnecting after a network interruption.

| Check | What it verifies |
|-------|-----------------|
| NTP service active | `timedatectl status` shows `NTP service: active` |
| Clock synchronized | `timedatectl status` shows `System clock synchronized: yes` |

**Fix:**
```bash
sudo timedatectl set-ntp true
```

---

### 10. Swap

**Why:** minty has 32GB RAM, but a runaway process can exhaust memory and trigger the OOM (out-of-memory) killer, which may terminate tailscaled or rustdesk. Swap provides a buffer that prevents the OOM killer from targeting remote-access services.

| Check | What it verifies |
|-------|-----------------|
| Swap present | `free -h` shows swap > 0 |

**Fix** (create a 2GB swapfile):
```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
# Make permanent:
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

### 11. Kernel Panic Reboot

**Why:** If the kernel panics (hard crash), the default behavior is to hang forever — the machine is unreachable and requires a physical power cycle. Setting `kernel.panic > 0` causes an automatic reboot after N seconds. `kernel.panic_on_oops` escalates less severe kernel errors (oops) to full panics, ensuring they also trigger the auto-reboot.

| Check | What it verifies |
|-------|-----------------|
| kernel.panic > 0 | `sysctl kernel.panic` — auto-reboot is configured |
| kernel.panic_on_oops = 1 | Kernel oops escalated to panic → triggers reboot |

**Fix:**
```bash
echo 'kernel.panic = 10' | sudo tee /etc/sysctl.d/99-panic-reboot.conf
echo 'kernel.panic_on_oops = 1' | sudo tee -a /etc/sysctl.d/99-panic-reboot.conf
sudo sysctl -p /etc/sysctl.d/99-panic-reboot.conf
```

---

### 12. GRUB Boot Timeout

**Why:** After a crash or forced reboot, GRUB may present a boot menu and wait for keyboard input before proceeding. If `GRUB_TIMEOUT=-1`, it waits forever — the machine never finishes booting and remains unreachable.

| Check | What it verifies |
|-------|-----------------|
| GRUB_TIMEOUT set | Present in `/etc/default/grub` |
| GRUB_TIMEOUT ≠ -1 | Not set to wait forever |
| GRUB_TIMEOUT ≤ 10 | Boots automatically within a reasonable window |

**Fix** (`/etc/default/grub`):
```
GRUB_TIMEOUT=5
```
Then: `sudo update-grub`

---

### 13. Tailscale Key Expiry

**Why:** Tailscale auth keys expire by default. If a key expires while minty is offline (e.g. after a power outage), Tailscale will not reconnect when the machine comes back — it requires manual `tailscale up` re-authentication, which you can't do remotely because Tailscale is down.

| Check | What it verifies |
|-------|-----------------|
| Key expiry disabled | `KeyExpiry` in `tailscale status --json` is zero-value (`0001-01-01T00:00:00Z`) |
| Days remaining | If expiry is set: warns at ≤ 14 days, fails if already expired |

**Fix:** In the Tailscale admin console:
Machines → minty → ⋯ → Disable key expiry

---

## What is NOT checked (by design)

| Item | Reason omitted |
|------|---------------|
| Brute force protection (fail2ban) | Not needed — SSH is only reachable via Tailscale, not the public internet |
| Unattended upgrades | Hobbyist machine — manual `apt upgrade` is sufficient |
| Watchdog timer | Kernel panic reboot covers the hard-hang case; a full deadlock without panic is extremely rare on desktop Linux |
| BIOS AC power restore | Cannot be checked from the OS — must be set in BIOS/UEFI under Power Management → "Restore on AC Power" → Power On |

---

## Configuration constants

Defined at the top of the script — adjust if your setup changes:

```bash
TAILSCALE_HOSTNAME="minty.warg-torino.ts.net"
SSH_PORT=22
SSH_ALIVE_INTERVAL_MIN=30   # minimum acceptable ClientAliveInterval
SSH_ALIVE_COUNT_MIN=3        # minimum acceptable ClientAliveCountMax
TAILSCALE_OVERRIDE="/etc/systemd/system/tailscaled.service.d/override.conf"
```
