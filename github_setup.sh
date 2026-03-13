#!/usr/bin/env bash
# github_setup.sh
#
# Version 2c - mostly non-interactive GitHub deploy-key setup
#
# Flow:
#   - Requires GITHUB_USER and REPO_NAME via env vars or args
#   - Creates deploy key if missing
#   - Prints public key
#   - Gives prompt: type 'repo' after adding key in GitHub to continue
#   - Then configures SSH and tests repo access
#
# Usage:
#   sudo ./github_setup.sh <github_user_or_org> <repo_name>
#
# Or:
#   sudo GITHUB_USER="zartashtech" REPO_NAME="scripts" ./github_setup.sh

set -euo pipefail

echo "=============================================="
echo "GitHub setup v2c"
echo "=============================================="
echo ""

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

GITHUB_USER="$(printf '%s' "${GITHUB_USER}" | tr -d '[:space:]')"
REPO_NAME="$(printf '%s' "${REPO_NAME}" | tr -d '[:space:]')"

if [ -z "${GITHUB_USER}" ] || [ -z "${REPO_NAME}" ]; then
  echo "Error: GitHub username/org and repository name cannot be empty."
  exit 1
fi

case "${GITHUB_USER}" in
  *[!A-Za-z0-9._-]*)
    echo "Error: GitHub username/org contains invalid characters."
    exit 1
    ;;
esac

case "${REPO_NAME}" in
  *[!A-Za-z0-9._-]*)
    echo "Error: Repository name contains invalid characters."
    exit 1
    ;;
esac

SSH_DIR="${SSH_DIR:-/root/.ssh}"
SSH_KEY_NAME="${REPO_NAME}_deploy"
SSH_KEY_PATH="${SSH_DIR}/${SSH_KEY_NAME}"
SSH_CONFIG="${SSH_DIR}/config"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"
HOST_ALIAS="github-${REPO_NAME}"
REMOTE_URL="git@${HOST_ALIAS}:${GITHUB_USER}/${REPO_NAME}.git"

echo "GitHub user/org : ${GITHUB_USER}"
echo "Repository      : ${REPO_NAME}"
echo "SSH key path    : ${SSH_KEY_PATH}"
echo "SSH host alias  : ${HOST_ALIAS}"
echo ""

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: run this script as root or with sudo."
    exit 1
  fi
}

install_pkg_if_missing() {
  local cmd="$1"
  shift
  local pkgs=("$@")

  if ! command -v "${cmd}" >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y "${pkgs[@]}"
  fi
}

api_status() {
  local url="$1"
  curl -sS -o /dev/null -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: github-setup-script" \
    "$url"
}

ssh_config_has_host() {
  local host_alias="$1"
  [ -f "${SSH_CONFIG}" ] && grep -q "^Host ${host_alias}$" "${SSH_CONFIG}" 2>/dev/null
}

add_ssh_config_block() {
  local host_alias="$1"
  local key_path="$2"

  {
    echo ""
    echo "Host ${host_alias}"
    echo "  HostName github.com"
    echo "  User git"
    echo "  IdentityFile ${key_path}"
    echo "  IdentitiesOnly yes"
    echo "  StrictHostKeyChecking yes"
  } >> "${SSH_CONFIG}"
}

ensure_known_hosts() {
  touch "${KNOWN_HOSTS}"
  chmod 644 "${KNOWN_HOSTS}"

  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    ssh-keyscan github.com >> "${KNOWN_HOSTS}" 2>/dev/null || true
  fi
}

print_public_key_block() {
  echo ""
  echo "=============================================="
  echo "ADD THIS PUBLIC KEY TO GITHUB DEPLOY KEYS"
  echo "=============================================="
  echo "Repository:"
  echo "  ${GITHUB_USER}/${REPO_NAME}"
  echo ""
  echo "URL:"
  echo "  https://github.com/${GITHUB_USER}/${REPO_NAME}/settings/keys"
  echo ""
  echo "Title suggestion:"
  echo "  $(hostname)-${REPO_NAME}-deploy"
  echo ""
  echo "Public key:"
  echo "----------------------------------------------"
  cat "${SSH_KEY_PATH}.pub"
  echo "----------------------------------------------"
  echo ""
}

prompt_continue_after_key_add() {
  local answer=""

  if [ ! -t 0 ]; then
    echo "Key created. Now add it in GitHub Deploy Keys and run this script again."
    exit 0
  fi

  echo "After adding the key in GitHub, type: repo"
  echo "To stop now, press Enter or type anything else."
  echo -n "Continue now? "
  read -r answer

  if [ "${answer}" != "repo" ]; then
    echo "Stopped. Run the same command again after adding the key."
    exit 0
  fi
}

require_root

echo "=== [1] Checking dependencies ==="
install_pkg_if_missing curl curl
install_pkg_if_missing git git
if ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v ssh-keyscan >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y openssh-client
fi
echo "Dependencies OK"
echo ""

echo "=== [2] Lightweight GitHub validation ==="
OWNER_URL="https://api.github.com/users/${GITHUB_USER}"
OWNER_STATUS="$(api_status "${OWNER_URL}")"

if [ "${OWNER_STATUS}" = "200" ]; then
  echo "Owner/user/org appears to exist."
else
  echo "Warning: could not confirm owner/user/org publicly."
  echo "Checked: ${OWNER_URL}"
  echo "Continuing anyway."
fi

REPO_URL="https://api.github.com/repos/${GITHUB_USER}/${REPO_NAME}"
REPO_STATUS="$(api_status "${REPO_URL}")"

case "${REPO_STATUS}" in
  200)
    echo "Repository is publicly visible or publicly confirmable."
    ;;
  404)
    echo "Repository could not be confirmed publicly."
    echo "This is normal for many private repositories."
    echo "Continuing."
    ;;
  403)
    echo "GitHub API rate-limited or temporarily blocked public check."
    echo "Continuing."
    ;;
  *)
    echo "GitHub API returned HTTP ${REPO_STATUS} for repo check."
    echo "Continuing."
    ;;
esac
echo ""

echo "=== [3] Preparing SSH directory ==="
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
echo "SSH directory ready"
echo ""

echo "=== [4] Checking deploy key ==="
if [ ! -f "${SSH_KEY_PATH}" ]; then
  echo "Deploy key not found. Creating..."
  ssh-keygen -t ed25519 -C "deploy-${GITHUB_USER}-${REPO_NAME}" -f "${SSH_KEY_PATH}" -N ""
  chmod 600 "${SSH_KEY_PATH}"
  chmod 644 "${SSH_KEY_PATH}.pub"

  print_public_key_block
  prompt_continue_after_key_add
else
  echo "Deploy key already exists"
fi
echo ""

echo "=== [5] Configuring SSH ==="
if [ ! -f "${SSH_CONFIG}" ]; then
  touch "${SSH_CONFIG}"
  chmod 600 "${SSH_CONFIG}"
fi

if ssh_config_has_host "${HOST_ALIAS}"; then
  echo "SSH config entry already exists for ${HOST_ALIAS}"
else
  add_ssh_config_block "${HOST_ALIAS}" "${SSH_KEY_PATH}"
  echo "Added SSH config entry for ${HOST_ALIAS}"
fi
echo ""

echo "=== [6] Updating known_hosts ==="
ensure_known_hosts
echo "known_hosts ready"
echo ""

echo "=== [7] Testing SSH authentication ==="
SSH_TEST_OUTPUT="$(ssh -o BatchMode=yes -T git@${HOST_ALIAS} 2>&1 || true)"
echo "${SSH_TEST_OUTPUT}"
echo ""

if echo "${SSH_TEST_OUTPUT}" | grep -Eq "successfully authenticated|You've successfully authenticated"; then
  echo "SSH identity accepted by GitHub."
else
  echo "SSH authentication failed."
  echo ""
  echo "Please check:"
  echo "  1. Public key was added to Deploy Keys"
  echo "  2. It was added to repo: ${GITHUB_USER}/${REPO_NAME}"
  echo "  3. The correct key was pasted from: ${SSH_KEY_PATH}.pub"
  echo ""
  echo "Then run the same command again."
  exit 1
fi

echo "=== [8] Testing repository access ==="
if git ls-remote "${REMOTE_URL}" >/dev/null 2>&1; then
  echo "Repository access confirmed."
  echo ""
  echo "=============================================="
  echo "GitHub setup completed successfully"
  echo "=============================================="
  echo ""
  echo "Clone command:"
  echo "  git clone ${REMOTE_URL}"
  echo ""
  echo "If local repo already exists:"
  echo "  git remote set-url origin ${REMOTE_URL}"
  echo ""
else
  echo "SSH identity worked, but repository access failed."
  echo ""
  echo "Possible reasons:"
  echo "  1. Repo name is wrong"
  echo "  2. User/org name is wrong"
  echo "  3. Deploy key was added to a different repository"
  echo "  4. Deploy key has not been saved properly in GitHub"
  echo ""
  echo "Remote tested:"
  echo "  ${REMOTE_URL}"
  exit 1
fi
