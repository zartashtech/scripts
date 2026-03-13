#!/usr/bin/env bash
# Non-interactive GitHub deploy-key setup for a private repo.
#
# Usage:
#   sudo ./github_setup.sh <github_user_or_org> <repo_name>
#
# Or:
#   sudo GITHUB_USER="zartashtech" REPO_NAME="scripts" ./github_setup.sh
#
# First run:
#   - validates GitHub user/org and repo existence
#   - creates SSH key
#   - prints public key
#   - asks you to add it in GitHub Deploy Keys
#
# Second run:
#   - configures SSH
#   - tests authentication
#   - prints clone command
#
# Notes:
#   - This script is intentionally non-interactive.
#   - It validates repo existence using GitHub public API.
#   - Works best for repo-specific deploy keys.

set -euo pipefail

echo "=============================================="
echo "GitHub setup (non-interactive)"
echo "=============================================="
echo ""

# --------------------------------------------------
# Inputs
# --------------------------------------------------
GITHUB_USER="${GITHUB_USER:-${1:-}}"
REPO_NAME="${REPO_NAME:-${2:-}}"

if [ -z "${GITHUB_USER}" ] || [ -z "${REPO_NAME}" ]; then
  echo "Error: GitHub username/org and repository name are required."
  echo ""
  echo "Usage:"
  echo "  sudo ./github_setup.sh <github_user_or_org> <repo_name>"
  echo ""
  echo "Or:"
  echo "  sudo GITHUB_USER=\"youruser\" REPO_NAME=\"yourrepo\" ./github_setup.sh"
  exit 1
fi

# remove accidental spaces
GITHUB_USER="$(echo "${GITHUB_USER}" | tr -d '[:space:]')"
REPO_NAME="$(echo "${REPO_NAME}" | tr -d '[:space:]')"

if [ -z "${GITHUB_USER}" ] || [ -z "${REPO_NAME}" ]; then
  echo "Error: GitHub username/org and repository name cannot be empty."
  exit 1
fi

SSH_DIR="${SSH_DIR:-/root/.ssh}"
SSH_KEY_NAME="${REPO_NAME}_deploy"
SSH_KEY_PATH="${SSH_DIR}/${SSH_KEY_NAME}"
SSH_CONFIG="${SSH_DIR}/config"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"
HOST_ALIAS="github-${REPO_NAME}"

echo "GitHub user/org : ${GITHUB_USER}"
echo "Repository      : ${REPO_NAME}"
echo "SSH key path    : ${SSH_KEY_PATH}"
echo "SSH host alias  : ${HOST_ALIAS}"
echo ""

# --------------------------------------------------
# Dependencies
# --------------------------------------------------
echo "=== [1] Checking dependencies ==="

if ! command -v curl >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y curl
fi

if ! command -v git >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y git
fi

if ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v ssh-keyscan >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y openssh-client
fi

echo "Dependencies OK"
echo ""

# --------------------------------------------------
# GitHub validation helpers
# --------------------------------------------------
github_api_get_status() {
  local url="$1"
  curl -sS -o /dev/null -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: github-setup-script" \
    "$url"
}

github_api_get_body() {
  local url="$1"
  curl -sS \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: github-setup-script" \
    "$url"
}

# --------------------------------------------------
# Validate GitHub user/org exists
# --------------------------------------------------
echo "=== [2] Validating GitHub user/org ==="

USER_URL="https://api.github.com/users/${GITHUB_USER}"
USER_STATUS="$(github_api_get_status "${USER_URL}")"

if [ "${USER_STATUS}" != "200" ]; then
  echo "Error: GitHub user/org '${GITHUB_USER}' not found."
  echo "Checked: ${USER_URL}"
  exit 1
fi

echo "User/org exists"
echo ""

# --------------------------------------------------
# Validate repository exists
# --------------------------------------------------
echo "=== [3] Validating repository ==="

REPO_URL="https://api.github.com/repos/${GITHUB_USER}/${REPO_NAME}"
REPO_STATUS="$(github_api_get_status "${REPO_URL}")"

if [ "${REPO_STATUS}" != "200" ]; then
  echo "Error: Repository '${GITHUB_USER}/${REPO_NAME}' not found or not publicly visible."
  echo "Checked: ${REPO_URL}"
  echo ""
  echo "Possible reasons:"
  echo "  1. Repository name is wrong"
  echo "  2. User/org name is wrong"
  echo "  3. Repository is private and GitHub API is not exposing it anonymously"
  echo ""
  echo "If the repo is private, make sure the owner/repo names are exactly correct."
  exit 1
fi

REPO_BODY="$(github_api_get_body "${REPO_URL}")"
if echo "${REPO_BODY}" | grep -q '"private":[[:space:]]*true'; then
  REPO_VISIBILITY="private"
elif echo "${REPO_BODY}" | grep -q '"private":[[:space:]]*false'; then
  REPO_VISIBILITY="public"
else
  REPO_VISIBILITY="unknown"
fi

echo "Repository exists"
echo "Repository visibility: ${REPO_VISIBILITY}"
echo ""

# --------------------------------------------------
# Prepare SSH directory
# --------------------------------------------------
echo "=== [4] Preparing SSH directory ==="
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
echo "SSH directory ready"
echo ""

# --------------------------------------------------
# Create deploy key if missing
# --------------------------------------------------
echo "=== [5] Checking deploy key ==="

if [ ! -f "${SSH_KEY_PATH}" ]; then
  echo "Deploy key does not exist. Creating..."
  ssh-keygen -t ed25519 -C "deploy-${GITHUB_USER}-${REPO_NAME}" -f "${SSH_KEY_PATH}" -N ""
  chmod 600 "${SSH_KEY_PATH}"
  chmod 644 "${SSH_KEY_PATH}.pub"

  echo ""
  echo "=============================================="
  echo "ADD THIS PUBLIC KEY TO GITHUB DEPLOY KEYS"
  echo "Repository:"
  echo "  ${GITHUB_USER}/${REPO_NAME}"
  echo ""
  echo "URL:"
  echo "  https://github.com/${GITHUB_USER}/${REPO_NAME}/settings/keys"
  echo ""
  echo "Public key:"
  echo "----------------------------------------------"
  cat "${SSH_KEY_PATH}.pub"
  echo "----------------------------------------------"
  echo ""
  echo "Run the same command again after adding the key."
  echo "=============================================="
  exit 0
else
  echo "Deploy key already exists"
fi

echo ""

# --------------------------------------------------
# SSH config
# --------------------------------------------------
echo "=== [6] Configuring SSH ==="

if [ ! -f "${SSH_CONFIG}" ]; then
  touch "${SSH_CONFIG}"
  chmod 600 "${SSH_CONFIG}"
fi

if ! grep -q "^Host ${HOST_ALIAS}$" "${SSH_CONFIG}" 2>/dev/null; then
  {
    echo ""
    echo "Host ${HOST_ALIAS}"
    echo "  HostName github.com"
    echo "  User git"
    echo "  IdentityFile ${SSH_KEY_PATH}"
    echo "  IdentitiesOnly yes"
  } >> "${SSH_CONFIG}"
  echo "Added SSH config entry for ${HOST_ALIAS}"
else
  echo "SSH config entry already exists for ${HOST_ALIAS}"
fi

echo ""

# --------------------------------------------------
# known_hosts
# --------------------------------------------------
echo "=== [7] Updating known_hosts ==="

touch "${KNOWN_HOSTS}"
chmod 644 "${KNOWN_HOSTS}"

if ! ssh-keygen -F github.com >/dev/null 2>&1; then
  ssh-keyscan github.com >> "${KNOWN_HOSTS}" 2>/dev/null || true
  echo "github.com added to known_hosts"
else
  echo "github.com already present in known_hosts"
fi

echo ""

# --------------------------------------------------
# Test SSH auth
# --------------------------------------------------
echo "=== [8] Testing SSH authentication ==="

SSH_TEST_OUTPUT="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -T git@${HOST_ALIAS} 2>&1 || true)"
echo "${SSH_TEST_OUTPUT}"
echo ""

if echo "${SSH_TEST_OUTPUT}" | grep -Eq "successfully authenticated|You've successfully authenticated"; then
  echo "=============================================="
  echo "GitHub setup completed successfully"
  echo ""
  echo "Clone command:"
  echo "  git clone git@${HOST_ALIAS}:${GITHUB_USER}/${REPO_NAME}.git"
  echo ""
  echo "If repo already exists locally:"
  echo "  git remote set-url origin git@${HOST_ALIAS}:${GITHUB_USER}/${REPO_NAME}.git"
  echo "=============================================="
else
  echo "Authentication test failed."
  echo ""
  echo "Please confirm:"
  echo "  1. The deploy key from ${SSH_KEY_PATH}.pub was added"
  echo "  2. It was added to repo: ${GITHUB_USER}/${REPO_NAME}"
  echo "  3. The deploy key is enabled"
  echo ""
  echo "Then run the same command again."
  exit 1
fi
