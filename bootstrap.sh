#!/bin/bash
# bootstrap.sh — one-click entry point.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/Kris69445578/jahimvj/main/bootstrap.sh | sudo bash
#
# Clones the repo into /opt/sshpanel-src and runs install.sh.

set -e

REPO_URL="https://github.com/Kris69445578/jahimvj.git"
CLONE_DIR="/opt/sshpanel-src"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root (use sudo)."
    exit 1
fi

apt update -y
apt install -y git

if [ -d "$CLONE_DIR" ]; then
    echo "== existing clone found, pulling latest =="
    git -C "$CLONE_DIR" pull
else
    echo "== cloning $REPO_URL =="
    git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
fi

cd "$CLONE_DIR"
chmod +x install.sh manage-ssh.sh menu.sh wsproxy.py
bash install.sh
