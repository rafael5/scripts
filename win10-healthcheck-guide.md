# win10-healthcheck.ps1 — guide

Comprehensive privacy / telemetry / performance / stability / security audit for
the **offline Windows 10 CPRS test VM** (`win10_x64` in VirtualBox). It runs
*inside* the guest (Windows registry/services/WMI can't be read from the Linux
host), reports every finding with a colored glyph, and prints the exact
remediation command. Default run changes **nothing**; `-Harden` applies the safe
fixes.

## What it checks (11 domains)

1. **System identity & offline posture** — build/edition, NICs, and whether the
   VM can reach the public internet (it shouldn't).
2. **Microsoft telemetry** — DiagTrack + dmwappushservice, `AllowTelemetry=0`,
   advertising ID, tailored experiences, AIT, CEIP, and the CEIP/Application-
   Experience/Feedback scheduled tasks.
3. **Cortana / web search / Bing** — Cortana off, web results off, search indexer.
4. **Windows Update & forced updates** — `NoAutoUpdate`, wuauserv, WaaSMedicSvc
   (the service that silently re-enables WU), UsoSvc, Delivery Optimization P2P,
   UpdateOrchestrator tasks.
5. **Defender cloud** — MAPS/SpyNet reporting off, sample submission never-send,
   SmartScreen off, signature age (informational on an offline box).
6. **Privacy surveillance** — geolocation, Windows Error Reporting, consumer
   features/suggested apps, activity history, online speech, OneDrive.
7. **Bloat / performance services** — SysMain, Xbox stack, Maps, Fax, Retail
   Demo, Remote Registry, Connected Devices, print spooler (only if no real
   printers), and HKLM/HKCU Run-key startup items.
8. **Resource health** — memory % + top consumers, CPU load, per-volume free
   space, virtual-disk health, dirty bit, Update-cache / TEMP bloat.
9. **Stability** — uptime, pending reboot, unexpected shutdowns (6008), BSOD
   bugchecks (1001), disk I/O errors (7/51/153), minidumps, SFC/DISM reminder.
10. **Security posture** — firewall on all profiles, UAC, RDP, SMBv1, cleartext
    autologin password, Guest account, AutoRun.
11. **Network-egress hardening** — NCSI active probe off, live connections to
    public IPs, hosts-file telemetry blocklist.

Glyphs: `✔` green OK · `⚠` yellow WARN · `✘` red FAIL · `·` cyan INFO. Use
`-Ascii` if the console renders boxes. Exit code: `0` healthy / `1` warnings /
`2` failures.

## Running it inside the VM

Copy the script in and run from an **elevated** PowerShell (right-click → Run as
administrator):

```powershell
# audit only (read-only) — default
powershell -ExecutionPolicy Bypass -File .\win10-healthcheck.ps1

# audit + write a transcript log to %USERPROFILE%
powershell -ExecutionPolicy Bypass -File .\win10-healthcheck.ps1 -Report

# apply the safe telemetry/service/registry hardening (elevated required)
powershell -ExecutionPolicy Bypass -File .\win10-healthcheck.ps1 -Harden
```

`-Harden` only enforces the telemetry/service/registry desired-state items
(idempotent). It never touches the resource/stability/security *audits* — those
are report-only. Reboot after a `-Harden` run, then re-run in audit mode to
confirm everything is green.

## Getting the script into the VM (from the Linux host)

**Option A — VBox guest control** (needs the guest user + password):

```bash
VBoxManage guestcontrol win10_x64 --username rmric --password '<pw>' \
  copyto ~/scripts/win10-healthcheck.ps1 'C:\Users\rmric\win10-healthcheck.ps1'

VBoxManage guestcontrol win10_x64 --username rmric --password '<pw>' \
  run --exe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -- \
  powershell -ExecutionPolicy Bypass -File 'C:\Users\rmric\win10-healthcheck.ps1' -Report
```

> Guest control needs an **elevated** guest session for the `-Harden` run and for
> full coverage; some checks (firewall profiles, service start modes) report
> partial data from a non-admin session.

**Option B — shared folder**: add `~/scripts` as a VirtualBox shared folder, then
run the `.ps1` from the mapped drive inside the guest.

**Option C — copy/paste**: paste the file contents into Notepad in the guest,
save as `win10-healthcheck.ps1`, run as above.

## Offline-VM note

This is a NAT'd VM (`10.0.2.15`), so it *can* reach the internet through the host
NAT. For a genuinely offline test box, set the adapter to Host-only or detach it:

```bash
VBoxManage modifyvm win10_x64 --nic1 hostonly    # or: --nic1 null
```

Use **VirtualBox snapshots** as the rollback mechanism (take one before
`-Harden`):

```bash
VBoxManage snapshot win10_x64 take pre-harden --description "before healthcheck -Harden"
```
