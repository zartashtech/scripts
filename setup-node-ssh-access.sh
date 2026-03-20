#!/usr/bin/env bash
# Run on a REMOTE NODE to allow SSH from monitoring server.
# This script asks for target username and monitoring server PUBLIC key.
# Usage:
#   bash setup-node-ssh-access.sh

set -euo pipefail

echo "=============================================="
echo "Remote node SSH access setup"
echo "=============================================="
echo "This script appends monitoring server PUBLIC key to authorized_keys."
echo "Do NOT paste a private key."
echo

read -r -p "Target server username for SSH access [root]: " TARGET_USER
TARGET_USER="${TARGET_USER:-root}"

if [[ "${TARGET_USER}" == "root" ]]; then
  HOME_DIR="/root"
else
  HOME_DIR="/home/${TARGET_USER}"
fi

echo
echo "Paste monitoring server PUBLIC key (single line, starts with ssh-ed25519 or ssh-rsa):"
read -r PUB_KEY

if [[ -z "${PUB_KEY}" ]]; then
  echo "ERROR: Public key is empty."
  exit 1
fi
if [[ "${PUB_KEY}" != ssh-ed25519* && "${PUB_KEY}" != ssh-rsa* && "${PUB_KEY}" != ecdsa-* ]]; then
  echo "ERROR: Key format does not look like a public key."
  echo "Expected prefixes: ssh-ed25519 / ssh-rsa / ecdsa-*"
  exit 1
fi

SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

ensure_with_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    bash -c "$1"
  else
    if ! command -v sudo >/dev/null 2>&1; then
      echo "ERROR: sudo not found and you are not root."
      exit 1
    fi
    sudo bash -c "$1"
  fi
}

ensure_with_sudo "mkdir -p '${SSH_DIR}'"
ensure_with_sudo "chmod 700 '${SSH_DIR}'"
ensure_with_sudo "touch '${AUTH_KEYS}'"

if [[ "${EUID}" -eq 0 ]]; then
  grep -qxF "${PUB_KEY}" "${AUTH_KEYS}" 2>/dev/null || echo "${PUB_KEY}" >> "${AUTH_KEYS}"
else
  sudo bash -c "grep -qxF '${PUB_KEY}' '${AUTH_KEYS}' 2>/dev/null || echo '${PUB_KEY}' >> '${AUTH_KEYS}'"
fi

ensure_with_sudo "chmod 600 '${AUTH_KEYS}'"

if [[ "${TARGET_USER}" != "root" ]]; then
  ensure_with_sudo "chown -R '${TARGET_USER}:${TARGET_USER}' '${SSH_DIR}'"
fi

echo
echo "Done."
echo "User: ${TARGET_USER}"
echo "Path: ${AUTH_KEYS}"
echo "Next: run 'make ssh-nodes-verify' on monitoring server."
