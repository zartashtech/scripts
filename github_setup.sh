#!/usr/bin/env bash
# Standalone GitHub setup: create SSH deploy key so the server can clone/pull a PRIVATE repo.
# Place this script in a PUBLIC repo or public URL – run it on the server BEFORE you have the
# private repo. Then add the printed key in GitHub (Deploy keys), run again, and clone with SSH.
#
# Usage (on the server, as root):
#   curl -sSL https://your-public-url/github_setup.sh -o github_setup.sh && sudo bash github_setup.sh
# Script will ask for GitHub username and repository name (or set GITHUB_USER and REPO_NAME in env).

set -euo pipefail

echo "=============================================="
echo "GitHub setup (standalone – no repo needed)"
echo "=============================================="
echo ""

if [[ -z "${GITHUB_USER:-}" ]]; then
  read -rp "GitHub username or organization: " GITHUB_USER
  GITHUB_USER="$(echo "${GITHUB_USER}" | tr -d '[:space:]')"
fi
if [[ -z "${REPO_NAME:-}" ]]; then
  read -rp "Repository name: " REPO_NAME
  REPO_NAME="$(echo "${REPO_NAME}" | tr -d '[:space:]')"
fi

if [[ -z "${GITHUB_USER}" || -z "${REPO_NAME}" ]]; then
  echo "Error: GitHub username and repository name are required."
  exit 1
fi

SSH_KEY_NAME="${REPO_NAME}_deploy"
SSH_DIR="${SSH_DIR:-/root/.ssh}"
SSH_KEY_PATH="${SSH_DIR}/${SSH_KEY_NAME}"
SSH_CONFIG="${SSH_DIR}/config"

echo ""
echo "Key path: ${SSH_KEY_PATH}"
echo ""

# Git
if ! command -v git &>/dev/null; then
  echo "=== [1] Installing Git ==="
  apt-get update -qq && apt-get install -y git
else
  echo "=== [1] Git already installed ==="
fi

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

# Create key if missing
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  echo "=== [2] Creating SSH deploy key ==="
  ssh-keygen -t ed25519 -C "deploy-${REPO_NAME}" -f "${SSH_KEY_PATH}" -N ""
  chmod 600 "${SSH_KEY_PATH}"
  chmod 644 "${SSH_KEY_PATH}.pub"
  echo ""
  echo "=== ADD THIS KEY IN GITHUB ==="
  echo "   https://github.com/${GITHUB_USER}/${REPO_NAME}/settings/keys"
  echo "   Deploy keys → Add deploy key (read-only)"
  echo ""
  cat "${SSH_KEY_PATH}.pub"
  echo ""
  echo "After adding the key above, run this script again to set SSH config and test."
  exit 0
fi

# SSH config for github.com
echo "=== [3] SSH config for github.com ==="
if [[ ! -f "${SSH_CONFIG}" ]]; then
  touch "${SSH_CONFIG}"
  chmod 600 "${SSH_CONFIG}"
fi
if ! grep -q "Host github.com" "${SSH_CONFIG}" 2>/dev/null; then
  echo "" >> "${SSH_CONFIG}"
  echo "Host github.com" >> "${SSH_CONFIG}"
  echo "  HostName github.com" >> "${SSH_CONFIG}"
  echo "  User git" >> "${SSH_CONFIG}"
  echo "  IdentityFile ${SSH_KEY_PATH}" >> "${SSH_CONFIG}"
  echo "   Added github.com to ${SSH_CONFIG}"
else
  echo "   github.com already in ${SSH_CONFIG}"
fi

# Test
echo ""
echo "=== [4] Testing SSH to GitHub ==="
if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
  echo "   OK – You can now clone the private repo:"
  echo "   git clone git@github.com:${GITHUB_USER}/${REPO_NAME}.git"
else
  echo "   Failed. Ensure the deploy key was added in GitHub (read-only)."
  exit 1
fi

echo ""
echo "=============================================="
echo "GitHub setup done. Next: clone your private repo."
echo "   git clone git@github.com:${GITHUB_USER}/${REPO_NAME}.git"
echo "=============================================="
