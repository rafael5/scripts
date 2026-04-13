# git-ssh-setup — Guide

## Purpose

Step-by-step interactive wizard to convert a git repository from HTTPS (Personal
Access Token) authentication to SSH key authentication with GitHub. Walks the user
through every manual action — key generation, GitHub web UI steps, remote URL
update, and a push test — with explicit pauses between each step.

## Design

A guided interactive script rather than a fully automated one. Several steps
require browser interaction (adding the key to GitHub) or user decisions (which
email to use, GitHub username and repo name). The script handles all terminal-side
actions automatically; it pauses at each manual browser step and waits for
`Enter` to continue.

Designed to be run once per repository when migrating from HTTPS to SSH. The
`id_ed25519` key is reused if it already exists, so the wizard is safe to run
on a machine that already has an SSH key configured for other repos.

## Features

- Checks for an existing `~/.ssh/id_ed25519` before generating a new key
- Generates ed25519 key (current GitHub recommended type)
- Starts `ssh-agent` and loads the key
- Displays the public key for copying to clipboard
- Opens `https://github.com/settings/keys` in the browser
- Updates `origin` remote from HTTPS to `git@github.com:`
- Tests authentication with `ssh -T git@github.com`
- Completes with a `git push -u origin main`

## Functions

No extracted functions — 10 numbered inline steps with pauses:

| Step | Action | Automated? |
|------|--------|-----------|
| 1 | List `~/.ssh` directory | Auto |
| 2 | Generate ed25519 key if absent | Auto (prompts for email) |
| 3 | Start `ssh-agent` | Auto |
| 4 | `ssh-add ~/.ssh/id_ed25519` | Auto |
| 5 | Display public key | Auto (manual copy required) |
| 6 | Open GitHub SSH key settings | Auto (manual browser step) |
| 7 | Show current `git remote -v` | Auto |
| 8 | Update remote to SSH URL | Auto (prompts for username + repo) |
| 9 | `ssh -T git@github.com` | Auto |
| 10 | `git push -u origin main` | Auto |

## Use

```bash
# Run from inside the repository to convert
cd /path/to/repo
git-ssh-setup.sh
```

The script prompts for:
- GitHub email address (for key comment)
- GitHub username
- Repository name

## Notes

- Requires a browser to be available for step 6 (adds key to GitHub)
- Works with any GitHub repository; the remote is updated to
  `git@github.com:<user>/<repo>.git`
- If `id_ed25519` already exists, step 2 is skipped — the existing key is used
- `open` command is used to launch the browser (may need adjusting on Linux
  if `xdg-open` is preferred)
- Step 10 pushes `main` — edit the script if your default branch is different
