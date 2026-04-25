#!/bin/bash

set -e

echo "== Fixing system trash directories =="
sudo mkdir -p /.Trash /.Trash-1000
sudo chmod 1777 /.Trash /.Trash-1000

echo "== Fixing home directory ownership =="
sudo chown -R rafael:rafael /home/rafael

echo "== Resetting user trash =="
rm -rf /home/rafael/.local/share/Trash
mkdir -p /home/rafael/.local/share/Trash/files
mkdir -p /home/rafael/.local/share/Trash/info
chmod 700 /home/rafael/.local/share/Trash

echo "== Cleaning Chrome remnants =="
rm -rf /home/rafael/.config/google-chrome
rm -rf /home/rafael/.cache/google-chrome

echo "== Fixing /tmp permissions =="
sudo chmod 1777 /tmp

echo "== Reinstalling Google Chrome =="
cd /home/rafael/Downloads

if [ ! -f google-chrome-stable_current_amd64.deb ]; then
    echo "Downloading Chrome..."
    wget -O google-chrome-stable_current_amd64.deb \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
fi

sudo apt install -y ./google-chrome-stable_current_amd64.deb

echo "== Testing Chrome launch (profile isolation) =="
google-chrome --user-data-dir=/tmp/chrome-test >/dev/null 2>&1 &

echo "== DONE =="
echo "If Chrome opened successfully, system is fixed."
