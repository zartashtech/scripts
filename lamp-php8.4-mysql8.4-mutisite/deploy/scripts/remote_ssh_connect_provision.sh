#!/usr/bin/env bash
# deploy/scripts/remote_ssh_connect_provision.sh
#
# Run on a REMOTE machine to allow SSH from another server (staging, monitoring, etc.).
# Appends the caller's PUBLIC key to the chosen user's ~/.ssh/authorized_keys.
#
# Usage (interactive):
#   bash remote_ssh_connect_provision.sh
#
# Optional non-interactive:
#   export TARGET_USER=root
#   printf '%s\n' "$PUBKEY_LINE" | sudo -E bash remote_ssh_connect_provision.sh
#
# Do NOT paste a private key.

set -euo pipefail

echo "=============================================="
echo "Remote node SSH access setup"
echo "=============================================="
echo "This script appends the connecting server's PUBLIC key to authorized_keys."
echo "Do NOT paste a private key."
echo

if [ -z "${TARGET_USER:-}" ]; then
  if [ -t 0 ]; then
    read -r -p "Target server username for SSH access [root]: " TARGET_USER
    TARGET_USER="${TARGET_USER:-root}"
  else
    # stdin is the pubkey pipe; do not consume it here
    TARGET_USER=root
  fi
fi

if [ "${TARGET_USER}" = "root" ]; then
  HOME_DIR="/root"
else
  HOME_DIR="/home/${TARGET_USER}"
fi

SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

if [ -t 0 ]; then
  echo
  echo "Paste connecting server PUBLIC key (single line, ssh-ed25519 / ssh-rsa / ecdsa-sha2-*):"
  read -r PUB_KEY
else
  read -r PUB_KEY
fi

if [ -z "${PUB_KEY}" ]; then
  echo "ERROR: Public key is empty." >&2
  exit 1
fi

PUB_KEY="$(printf '%s' "${PUB_KEY}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

key_ok=0
case "${PUB_KEY}" in
  ssh-ed25519\ *) key_ok=1 ;;
  ssh-rsa\ *) key_ok=1 ;;
  ecdsa-sha2-*) key_ok=1 ;;
esac

if [ "${key_ok}" -ne 1 ]; then
  echo "ERROR: Key format does not look like a public key." >&2
  echo "Expected prefixes: ssh-ed25519 / ssh-rsa / ecdsa-sha2-*" >&2
  exit 1
fi

ensure_with_sudo() {
  if [ "${EUID}" -eq 0 ]; then
    bash -c "$1"
  else
    if ! command -v sudo >/dev/null 2>&1; then
      echo "ERROR: sudo not found and you are not root." >&2
      exit 1
    fi
    sudo bash -c "$1"
  fi
}

ensure_with_sudo "mkdir -p '${SSH_DIR}'"
ensure_with_sudo "chmod 700 '${SSH_DIR}'"
ensure_with_sudo "touch '${AUTH_KEYS}'"

append_if_missing() {
  local f="$1"
  local line="$2"
  if grep -qFx -- "${line}" "${f}" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "${line}" >> "${f}"
}

if [ "${EUID}" -eq 0 ]; then
  append_if_missing "${AUTH_KEYS}" "${PUB_KEY}"
else
  if ! sudo grep -qFx -- "${PUB_KEY}" "${AUTH_KEYS}" 2>/dev/null; then
    printf '%s\n' "${PUB_KEY}" | sudo tee -a "${AUTH_KEYS}" >/dev/null
  fi
fi

ensure_with_sudo "chmod 600 '${AUTH_KEYS}'"

if [ "${TARGET_USER}" != "root" ]; then
  ensure_with_sudo "chown -R '${TARGET_USER}:${TARGET_USER}' '${SSH_DIR}'"
fi

echo
echo "Done."
echo "User: ${TARGET_USER}"
echo "Path: ${AUTH_KEYS}"
echo "Next: verify SSH from the connecting server (e.g. re-run ssh_db_bootstrap.sh on staging)."
