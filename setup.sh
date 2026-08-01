#!/bin/bash
# setup.sh — alternative one-click entry point (wget-friendly).
#
# Usage:
#   apt update -y && apt upgrade -y && \
#   wget -q https://raw.githubusercontent.com/Kris69445578/jahimvj/main/setup.sh && \
#   chmod +x setup.sh && sudo ./setup.sh

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
