#!/bin/bash
# =============================================================================
#  git-ssh-setup.sh
#  Version: 1.0.0
#  Target:  Linux/macOS with GitHub access
#
#  Purpose
#  Interactive 10-step wizard to convert a git repository from HTTPS (PAT)
#  authentication to SSH key authentication with GitHub.
#
#  Design
#  Guided interactive script — several steps require browser interaction (adding
#  the key to GitHub) or user input. Terminal-side actions are fully automated;
#  the script pauses at each manual step and waits for Enter. Uses ed25519 keys
#  (current GitHub recommendation). Skips key generation if id_ed25519 exists.
#
#  Features
#  - Checks for and reuses existing ~/.ssh/id_ed25519
#  - Generates ed25519 SSH key (prompts for email)
#  - Starts ssh-agent and loads the key
#  - Displays public key for clipboard copy
#  - Opens https://github.com/settings/keys in browser
#  - Updates origin remote to git@github.com: URL
#  - Tests SSH authentication with ssh -T git@github.com
#  - Completes with git push -u origin main
#
#  Steps
#  1  List ~/.ssh                         (auto)
#  2  Generate ed25519 key if absent      (prompts email)
#  3  Start ssh-agent                     (auto)
#  4  ssh-add ~/.ssh/id_ed25519           (auto)
#  5  Display public key                  (manual copy)
#  6  Open GitHub SSH key settings page  (manual browser step)
#  7  Show current git remote -v          (auto)
#  8  Update remote to SSH URL            (prompts username + repo)
#  9  ssh -T git@github.com               (auto)
#  10 git push -u origin main             (auto)
#
#  Use
#  cd /path/to/repo && git-ssh-setup.sh
# =============================================================================

BLUE_BOLD="\033[1;34m"
RESET="\033[0m"

echo -e "${BLUE_BOLD}=== Git SSH Auth Setup ===${RESET}"
echo "This script will help you convert your repository from HTTPS to SSH."

# 1️⃣ Check if an SSH key already exists
echo -e "\n${BLUE_BOLD}Step 1: Check for existing SSH keys${RESET}"
ls ~/.ssh
echo "Press ENTER to continue..."
read -r

# 2️⃣ Generate a new SSH key if needed
echo -e "\n${BLUE_BOLD}Step 2: Generate a new SSH key (if you don't have one)${RESET}"
read -p "Enter the email to associate with the SSH key (GitHub email): " SSH_EMAIL
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -C "$SSH_EMAIL"
else
    echo "  ✅ id_ed25519 already exists, skipping key generation."
fi
echo "Press ENTER to continue..."
read -r

# 3️⃣ Start the SSH agent
echo -e "\n${BLUE_BOLD}Step 3: Start the SSH agent${RESET}"
eval "$(ssh-agent -s)"
echo "Press ENTER to continue..."
read -r

# 4️⃣ Add the key to the agent
echo -e "\n${BLUE_BOLD}Step 4: Add SSH key to agent${RESET}"
ssh-add ~/.ssh/id_ed25519
echo "Press ENTER to continue..."
read -r

# 5️⃣ Display the public key for GitHub
echo -e "\n${BLUE_BOLD}Step 5: Copy your SSH public key to GitHub${RESET}"
echo "Your public key is:"
echo "------------------------------------"
cat ~/.ssh/id_ed25519.pub
echo "------------------------------------"
echo "Copy the above key to your clipboard."
echo "Press ENTER when ready..."
read -r

# 6️⃣ Open GitHub SSH key page
echo -e "\n${BLUE_BOLD}Step 6: Add the SSH key to GitHub${RESET}"
echo "Opening GitHub SSH key settings in your default browser..."
open "https://github.com/settings/keys"
echo "Add a new SSH key and paste the public key from Step 5."
echo "Press ENTER when you have added the key..."
read -r

# 7️⃣ Show current Git remote
echo -e "\n${BLUE_BOLD}Step 7: Check current Git remote${RESET}"
git remote -v
echo "Press ENTER to continue..."
read -r

# 8️⃣ Update remote to SSH
echo -e "\n${BLUE_BOLD}Step 8: Update repository remote to use SSH${RESET}"
read -p "Enter your GitHub username: " GH_USER
read -p "Enter your repository name: " REPO_NAME
git remote set-url origin git@github.com:$GH_USER/$REPO_NAME.git
echo "Remote updated to SSH:"
git remote -v
echo "Press ENTER to continue..."
read -r

# 9️⃣ Test SSH authentication
echo -e "\n${BLUE_BOLD}Step 9: Test SSH authentication${RESET}"
ssh -T git@github.com
echo "Press ENTER to continue..."
read -r

# 🔟 Push to GitHub
echo -e "\n${BLUE_BOLD}Step 10: Push your branch to GitHub using SSH${RESET}"
git push -u origin main

echo -e "\n${BLUE_BOLD}✅ SSH setup complete. Your repo is now using SSH for Git operations.${RESET}"
