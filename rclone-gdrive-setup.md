# rclone-gdrive-setup.md

# Rclone Google Drive Setup on Linux Mint

This document summarizes the **complete setup and configuration of rclone for Google Drive on Linux Mint**, including all lessons learned, problems encountered, and solutions.

---

## Step 0 — Prerequisites

* Linux Mint machine
* rclone installed (latest stable version recommended)
* Internet access
* Optional: another machine with a browser for OAuth if needed

---

## Step 1 — Backup or remove existing rclone config

```bash
mv ~/.config/rclone/rclone.conf ~/.config/rclone/rclone.conf.bak
```

* Start with a clean configuration.

---

## Step 2 — Start a new rclone remote

```bash
rclone config
```

* **New remote?** → `n`
* **Name** → `gdrive`
* **Storage type** → `drive`

---

## Step 3 — Set up Google Drive access

* **Client ID** → leave blank (press Enter)
* **Client Secret** → leave blank (press Enter)
* **Scope** → `1` (Full access)
* **Root folder ID** → leave blank
* **Service Account File** → leave blank

---

## Step 4 — Skip advanced config

* **Advanced config?** → `n`

---

## Step 5 — Disable auto config

* **Use auto config?** → `n`
* This avoids binding a local port and prevents the `bind: address already in use` error.

**Lesson learned:** On Linux Mint, rclone often fails to bind the default port 53682 for OAuth, causing repeated fatal errors. Disabling auto config bypasses this.

---

## Step 6 — Obtain manual OAuth URL

* rclone should print instructions like:

```text
For this to work, open the following URL in a browser:
https://accounts.google.com/o/oauth2/auth?client_id=...&scope=drive&redirect_uri=urn:ietf:wg:oauth:2.0:oob
```

* Copy the **entire URL**, ensure no line breaks.

**Problem encountered:** On some Linux Mint setups, `rclone authorize` failed with:

```
fatal error: config failed to refresh token: failed to start auth webserver: listen tcp 127.0.0.1:53682: bind: address already in use
```

**Solution:** Use manual OAuth via the printed URL or a different machine with a browser to generate the token.

---

## Step 7 — Open URL in browser

1. Paste the URL into a browser.
2. Log in to Google and approve rclone access.
3. Copy the **verification code** (not the URL).

---

## Step 8 — Paste code into rclone

At the prompt:

```text
config_token>
```

* Paste the verification code and press Enter.

* rclone will create the following in `~/.config/rclone/rclone.conf`:

```ini
[gdrive]
type = drive
scope = drive
token = {"access_token":"...","refresh_token":"...","expiry":"..."}
```

**Lesson learned:** Only paste the verification code, never the full URL.

---

## Step 9 — Verify remote

```bash
rclone lsd gdrive:
```

* Should list your Google Drive folders.
* No port conflicts, no 400 errors.

---

## Step 10 — Troubleshooting common issues

### 1. Port already in use

```bash
sudo lsof -i :53682
sudo kill -9 <PID>
```

* Confirms the port is free.
* Alternatively, specify a different port:

```bash
RCLONE_AUTH_PORT=53683 rclone authorize "drive"
```

### 2. 400 Bad Request Error

* Cause: URL copied incorrectly or truncated.
* Solution: Copy the entire URL exactly as printed, open in browser, paste only the verification code.

### 3. `rclone authorize` fails repeatedly

* Cause: Local webserver binding issue.
* Solution: Use manual OAuth (`auto config = n`) or generate token on another machine and paste JSON into `rclone.conf`.

---

## Step 11 — Key lessons learned

1. **Always disable auto config** on Linux Mint to avoid port conflicts.
2. **Never run `rclone authorize` on Linux Mint** if it fails — manual OAuth works reliably.
3. **Copy the full OAuth URL exactly**; paste only the verification code.
4. **If a port is stuck**, use `sudo lsof -i :PORT` and `sudo kill -9 PID` or change the OAuth port.
5. **Tokens can be generated on another machine** and pasted manually if your Mint machine cannot run the webserver.

---

## Step 12 — Ready for use

* After these steps, the `gdrive` remote is fully functional.
* You can now run sync, copy, or export scripts to download or convert Google Docs to ODT.

---

**End of rclone-gdrive-setup.md**
