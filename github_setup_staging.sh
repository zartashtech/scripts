#!/usr/bin/env bash
# github_setup_staging.sh
#
# SOURCE OF TRUTH: edit this file in **private** repo **staging_lamp_setup** at github-public/github_setup_staging.sh
# PUBLISHING: manually copy-paste this entire file into **public** repo **scripts** as github_setup_staging.sh (repo root, main). This is the **only** script from this repo intended for that public listing; dump helpers are fetched from staging over SSH.
#   https://github.com/zartashtech/scripts/blob/main/github_setup_staging.sh
# Servers **curl** that public file for deploy-key bootstrap (see docs/installation_guide_user.md). Public raw URL:
#   https://raw.githubusercontent.com/zartashtech/scripts/main/github_setup_staging.sh
#
# Run on the staging server (as root). Each run creates one deploy key + SSH host alias for a **private**
# GitHub repository, so the server can `git` clone/fetch that repo.
#
# Typical staging pair (run the script once per repo — two runs total):
#   1) staging_lamp_setup — this tooling repo (for git pull on the server; use a deploy key if the repo is private)
#   2) staging_websites   — website application code (deploy.sh / github_repo_ssh_url → this repo only)
#
# Flow: create deploy key → add in GitHub → Settings → Deploy keys (read-only) → re-run or continue.
#
# Usage (after curl from public scripts repo):
#   sudo bash github_setup_staging.sh <github_user_or_org> <repo_name>
#
# Examples (org zartashtech):
#   sudo bash github_setup_staging.sh zartashtech staging_lamp_setup
#   sudo bash github_setup_staging.sh zartashtech staging_websites
#
# MySQL source host — fetch **scripts/db_scripts/inventory_sql_dump_to_staging.sh** from the staging tooling clone (scp), run it, delete temp copy:
#   sudo bash github_setup_staging.sh sql-dump-to-staging \
#     --repo-path /opt/deploy/staging_lamp_setup \   # omit if default on staging
#     --ssh-key /home/LOGIN/.ssh/remote_ssh \        # omit for /home/$SUDO_USER/.ssh/remote_ssh
#     --staging root@staging.example.com --yes --remote-mysql-label tms [--ssh-port 22] [...]
#   With sudo, default --ssh-key is /home/$SUDO_USER/.ssh/remote_ssh (not /root/.ssh). Missing key: script creates ed25519 pair as that user. If SSH to staging fails, prints pubkey; interactive: press Enter to retry. CI/pipes: set GITHUB_SETUP_STAGING_NON_INTERACTIVE=1 to exit instead of prompting.
#
# Public **scripts** repo should ship **only** this file; the dump script lives under scripts/db_scripts/ on staging (not published separately).

STAGING_TOOLING_REPO_DEFAULT="${STAGING_TOOLING_REPO_DEFAULT:-/opt/deploy/staging_lamp_setup}"

ssh_strict_host_opt() {
  if [ "${SSH_STRICT_HOST_KEYS:-}" = "yes" ]; then
    printf '%s' "StrictHostKeyChecking=yes"
  else
    printf '%s' "StrictHostKeyChecking=accept-new"
  fi
}

# Print one authorized_keys line for a private key path (stderr). Returns 0 if a line was printed.
sql_dump_print_pubkey_for_private_key() {
  local ssh_key="$1"
  local staging_cli="${2:-}"
  local repo_root="${3:-${STAGING_TOOLING_REPO_DEFAULT}}"
  local pub_line=""
  [ -n "${ssh_key}" ] && [ -f "${ssh_key}" ] || return 1
  if [ -f "${ssh_key}.pub" ]; then
    pub_line="$(head -n 1 "${ssh_key}.pub")"
  elif command -v ssh-keygen >/dev/null 2>&1; then
    pub_line="$(ssh-keygen -y -f "${ssh_key}" 2>/dev/null)" || pub_line=""
  fi
  if [ -z "${pub_line}" ]; then
    echo "Could not read public key for ${ssh_key} (.pub missing; ssh-keygen -y failed)." >&2
    return 1
  fi
  echo "Private key used here: ${ssh_key}" >&2
  echo "Add this **one line** on staging (paste into remote_ssh_connect_provision.sh, or ${staging_cli%%@*}'s ~/.ssh/authorized_keys on the staging host):" >&2
  echo "${pub_line}" >&2
  echo "" >&2
  echo "On staging server, run: sudo bash ${repo_root}/scripts/remote_ssh_connect_provision.sh" >&2
  return 0
}

# After failed scp from staging: host-key help + print the public key for Permission denied (publickey).
sql_dump_hint_after_scp_fail() {
  local cli host ssh_key repo_root
  cli="${1:-}"
  ssh_key="${2:-}"
  repo_root="${3:-${STAGING_TOOLING_REPO_DEFAULT}}"
  host="${cli#*@}"
  [ "${host}" = "${cli}" ] && host="${cli}"
  echo "" >&2
  echo "scp/ssh from staging failed. Common fixes:" >&2
  echo "  • REMOTE HOST IDENTIFICATION HAS CHANGED → as root here: ssh-keygen -f /root/.ssh/known_hosts -R \"${host}\"" >&2
  echo "  • Permission denied (publickey) → on staging, authorize this **public** key for ${cli%%@*} (see below)." >&2
  echo "" >&2
  if [ -n "${ssh_key}" ] && [ -f "${ssh_key}" ]; then
    sql_dump_print_pubkey_for_private_key "${ssh_key}" "${cli}" "${repo_root}" \
      || true
    echo "(Then re-run sql-dump-to-staging from this host.)" >&2
  fi
}

# When --ssh-key path is missing: keygen hint + show pubkey from an existing login-user key if any.
sql_dump_hint_missing_ssh_key() {
  local want="${1:-}"
  local staging_cli="${2:-}"
  local repo_root="${3:-${STAGING_TOOLING_REPO_DEFAULT}}"
  local su="${SUDO_USER:-}"
  local uh cand
  echo "" >&2
  if [ -n "${su}" ] && [ "${su}" != "root" ] && [ -d "/home/${su}" ]; then
    uh="/home/${su}/.ssh"
    echo "No private key at: ${want}" >&2
    echo "Create one for dump uploads (no passphrase):" >&2
    echo "  sudo -u ${su} mkdir -p \"${uh}\" && sudo -u ${su} ssh-keygen -t ed25519 -f \"${uh}/remote_ssh\" -N \"\"" >&2
    echo "Then re-run with: --ssh-key ${uh}/remote_ssh" >&2
    echo "" >&2
    echo "If SSH to staging is not set up yet, add the matching **public** line on staging first — copy the line below:" >&2
    echo "" >&2
    for cand in "${uh}/remote_ssh" "${uh}/id_ed25519" "${uh}/id_rsa"; do
      if [ -f "${cand}" ]; then
        sql_dump_print_pubkey_for_private_key "${cand}" "${staging_cli}" "${repo_root}" && return 0
      fi
    done
    if [ -f "${want}.pub" ]; then
      echo "Found ${want}.pub but private key is missing — restore the private file or generate a new pair." >&2
      echo "Public line (for staging authorized_keys):" >&2
      head -n 1 "${want}.pub" >&2
      echo "" >&2
      echo "On staging: sudo bash ${repo_root}/scripts/remote_ssh_connect_provision.sh" >&2
      return 0
    fi
    echo "No existing key at ${uh}/remote_ssh, id_ed25519, or id_rsa — run the ssh-keygen line above, then:" >&2
    echo "  cat ${uh}/remote_ssh.pub" >&2
    echo "Paste that one line on staging, then re-run sql-dump-to-staging." >&2
  else
    echo "Create a key (e.g. ssh-keygen -t ed25519 -f ~/.ssh/remote_ssh -N \"\") and pass --ssh-key /full/path/to/private_key" >&2
  fi
  echo "" >&2
  echo "On staging: sudo bash ${repo_root}/scripts/remote_ssh_connect_provision.sh" >&2
}

sql_dump_non_interactive() {
  [ -n "${GITHUB_SETUP_STAGING_NON_INTERACTIVE:-}" ] && return 0
  [ ! -t 0 ] && return 0
  return 1
}

# Owner for mkdir/ssh-keygen: /home/USER/.ssh/KEY → USER; /root/.ssh → root; else existing .ssh dir owner (stat).
sql_dump_key_owner_for_path() {
  local key_path="$1"
  local d
  d="$(dirname -- "${key_path}")"
  case "${d}" in
    /root/.ssh)
      echo "root"
      return 0
      ;;
    /home/*/.ssh)
      local u="${d#/home/}"
      u="${u%/.ssh}"
      if id "${u}" >/dev/null 2>&1; then
        echo "${u}"
        return 0
      fi
      ;;
  esac
  if [ -d "${d}" ]; then
    local o
    o="$(stat -c '%U' "${d}" 2>/dev/null || true)"
    if [ -n "${o}" ] && [ "${o}" != "UNKNOWN" ] && id "${o}" >/dev/null 2>&1; then
      echo "${o}"
      return 0
    fi
  fi
  return 1
}

# Create SSH_KEY if missing (as owning user); loop until ssh to staging succeeds or non-interactive exit.
sql_dump_ensure_ssh_key_and_staging_access() {
  local sp="$1"
  local staging_cli="$2"
  local repo_root="$3"
  local owner
  local ssh_dir
  local host
  host="${staging_cli#*@}"
  [ "${host}" = "${staging_cli}" ] && host="${staging_cli}"
  ssh_dir="$(dirname -- "${SSH_KEY}")"

  if [ ! -f "${SSH_KEY}" ]; then
    owner="$(sql_dump_key_owner_for_path "${SSH_KEY}")" || {
      echo "Error: cannot infer Linux user to own ${SSH_KEY} — use /home/LOGIN/.ssh/remote_ssh or /root/.ssh/remote_ssh (or pass --ssh-key with such a path)." >&2
      sql_dump_hint_missing_ssh_key "${SSH_KEY}" "${staging_cli}" "${repo_root}"
      exit 1
    }
    echo "=== [sql-dump-to-staging] No key at ${SSH_KEY} — creating ed25519 key (user ${owner}) ===" >&2
    if [ "${owner}" = "root" ]; then
      mkdir -p "${ssh_dir}"
      chmod 700 "${ssh_dir}"
      ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -q
      chmod 600 "${SSH_KEY}"
    else
      sudo -u "${owner}" mkdir -p "${ssh_dir}"
      sudo -u "${owner}" chmod 700 "${ssh_dir}"
      sudo -u "${owner}" ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -q
      chmod 600 "${SSH_KEY}" 2>/dev/null || true
    fi
  fi

  if [ ! -f "${SSH_KEY}" ]; then
    echo "Error: SSH private key still missing: ${SSH_KEY}" >&2
    exit 1
  fi

  while true; do
    if ssh -i "${SSH_KEY}" -P "${sp}" \
      -o BatchMode=yes -o ConnectTimeout=30 -o "$(ssh_strict_host_opt)" \
      -o IdentitiesOnly=yes \
      -- "${staging_cli}" true >/dev/null 2>&1; then
      return 0
    fi
    echo "" >&2
    echo "=== [sql-dump-to-staging] SSH to ${staging_cli} failed (authorize key on staging, fix host key, or network) ===" >&2
    echo "  • Host key changed → as root here: ssh-keygen -f /root/.ssh/known_hosts -R \"${host}\"" >&2
    sql_dump_print_pubkey_for_private_key "${SSH_KEY}" "${staging_cli}" "${repo_root}" || true
    if sql_dump_non_interactive; then
      echo "Non-interactive session: set GITHUB_SETUP_STAGING_NON_INTERACTIVE= (unset) for Enter-to-retry, or fix SSH and re-run." >&2
      exit 1
    fi
    echo "After the key is authorized on staging, press Enter to retry (Ctrl+C to abort)..." >&2
    read -r _ || exit 1
  done
}

# scp one file from staging → temp; run it with same argv tail; always remove temp (trap).
sql_dump_run_fetched_from_staging() {
  set -euo pipefail
  local remote_rel_path="$1"
  shift
  local all_pass=("$@")

  local REPO_PATH="${REPO_PATH:-${STAGING_TOOLING_REPO_DEFAULT}}"
  local SSH_KEY=""
  local SSH_KEY_FROM_ARG=""
  local STAGING_SSH_CLI=""
  local SSH_PORT_OVERRIDE=""
  local i=0

  while [ "$i" -lt "${#all_pass[@]}" ]; do
    case "${all_pass[i]}" in
      --repo-path)
        REPO_PATH="${all_pass[i + 1]:-}"
        i=$((i + 2))
        continue
        ;;
      --ssh-key)
        SSH_KEY_FROM_ARG="${all_pass[i + 1]:-}"
        SSH_KEY="${SSH_KEY_FROM_ARG}"
        i=$((i + 2))
        continue
        ;;
      --ssh-port)
        SSH_PORT_OVERRIDE="${all_pass[i + 1]:-}"
        i=$((i + 2))
        continue
        ;;
      --staging)
        STAGING_SSH_CLI="${all_pass[i + 1]:-}"
        i=$((i + 2))
        continue
        ;;
    esac
    i=$((i + 1))
  done

  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: sql-dump modes require root (sudo)." >&2
    exit 1
  fi
  if [ -z "${STAGING_SSH_CLI}" ]; then
    echo "Error: --staging USER@HOST is required (staging server that has the tooling repo clone)." >&2
    exit 1
  fi

  # Default key: with sudo, use login user's ~/.ssh/remote_ssh (not /root/.ssh/remote_ssh).
  if [ -z "${SSH_KEY_FROM_ARG}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
      SSH_KEY="/home/${SUDO_USER}/.ssh/remote_ssh"
    else
      SSH_KEY="${HOME}/.ssh/remote_ssh"
    fi
  fi

  case "${SSH_KEY}" in
    *..*)
      echo "Error: unsafe .. in SSH key path: ${SSH_KEY}" >&2
      exit 1
      ;;
  esac
  if [[ "${SSH_KEY}" != /* ]]; then
    echo "Error: --ssh-key must be an absolute path (got: ${SSH_KEY})" >&2
    exit 1
  fi

  local sp="${SSH_PORT_OVERRIDE:-22}"
  case "${sp}" in
    *[!0-9]*)
      echo "Error: invalid --ssh-port: ${sp}" >&2
      exit 1
      ;;
  esac
  if [ "${sp}" -lt 1 ] || [ "${sp}" -gt 65535 ]; then
    echo "Error: SSH port out of range: ${sp}" >&2
    exit 1
  fi

  local remote_full="${REPO_PATH}/${remote_rel_path}"
  case "${remote_full}" in
    *..*)
      echo "Error: unsafe path (..) in remote path: ${remote_full}" >&2
      exit 1
      ;;
  esac

  if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y --no-install-recommends openssh-client
  fi

  sql_dump_ensure_ssh_key_and_staging_access "${sp}" "${STAGING_SSH_CLI}" "${REPO_PATH}"

  local tmp
  tmp="$(mktemp)"
  chmod 600 "${tmp}"
  cleanup_tmp() {
    rm -f -- "${tmp}"
  }
  trap cleanup_tmp EXIT

  echo "=== [bootstrap] Copying ${remote_rel_path} from ${STAGING_SSH_CLI} (temporary file, removed after run) ==="
  if ! scp -i "${SSH_KEY}" -P "${sp}" \
    -o BatchMode=yes -o ConnectTimeout=30 -o "$(ssh_strict_host_opt)" \
    -o IdentitiesOnly=yes \
    -- "${STAGING_SSH_CLI}:${remote_full}" "${tmp}"; then
    echo "Error: scp failed for ${STAGING_SSH_CLI}:${remote_full}" >&2
    sql_dump_hint_after_scp_fail "${STAGING_SSH_CLI}" "${SSH_KEY}" "${REPO_PATH}"
    exit 1
  fi

  # Inner script defaults SSH_KEY to $HOME/.ssh/remote_ssh (root → wrong path). Pass resolved key via env.
  export SSH_KEY

  echo "=== [bootstrap] Running fetched script on this host (mysqldump → staging); next lines are from inventory_sql_dump_to_staging.sh ===" >&2
  local ec=0
  bash "${tmp}" "${all_pass[@]}" || ec=$?
  if [ "${ec}" -ne 0 ]; then
    echo "=== [bootstrap] Dump script exited with code ${ec} (see errors above) ===" >&2
  fi
  cleanup_tmp
  trap - EXIT
  exit "${ec}"
}

case "${1:-}" in
  sql-dump-to-staging)
    shift
    sql_dump_run_fetched_from_staging "scripts/db_scripts/inventory_sql_dump_to_staging.sh" "$@"
    ;;
esac

set -euo pipefail

echo "=============================================="
echo "GitHub staging setup (deploy key)"
echo "=============================================="
echo ""

GITHUB_USER="${GITHUB_USER:-${1:-}}"
REPO_NAME="${REPO_NAME:-${2:-}}"

if [ -z "${GITHUB_USER}" ] || [ -z "${REPO_NAME}" ]; then
  echo "Error: GitHub username/org and repository name are required."
  echo ""
  echo "Usage:"
  echo "  sudo bash github_setup_staging.sh <github_user_or_org> <repo_name>"
  echo ""
  echo "Get this file:"
  echo "  curl -sSL https://raw.githubusercontent.com/zartashtech/scripts/main/github_setup_staging.sh -o github_setup_staging.sh"
  echo ""
  echo "Typical (deploy keys for staging_lamp_setup + staging_websites):"
  echo "  sudo bash github_setup_staging.sh zartashtech staging_lamp_setup"
  echo "  sudo bash github_setup_staging.sh zartashtech staging_websites"
  echo ""
  echo "MySQL source host — fetch dump helper from staging (temp), run, delete:"
  echo "  sudo bash github_setup_staging.sh sql-dump-to-staging \\"
  echo "    --repo-path /opt/deploy/staging_lamp_setup \\"
  echo "    --ssh-key /home/LOGIN/.ssh/remote_ssh \\"
  echo "    --staging root@STAGING --yes --remote-mysql-label NAME"
  echo "  (Drop --repo-path / --ssh-key when defaults apply. Creates key if missing; Enter-to-retry SSH. CI: GITHUB_SETUP_STAGING_NON_INTERACTIVE=1.)"
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
    apt-get install -y --no-install-recommends "${pkgs[@]}"
  fi
}

api_status() {
  local url="$1"
  curl -sS -o /dev/null -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: github-setup-staging" \
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
  apt-get install -y --no-install-recommends openssh-client
fi
echo "Dependencies OK"
echo ""

echo "=== [2] Lightweight GitHub validation ==="
OWNER_URL="https://api.github.com/users/${GITHUB_USER}"
OWNER_STATUS="$(api_status "${OWNER_URL}")"
if [ "${OWNER_STATUS}" != "200" ]; then
  OWNER_URL="https://api.github.com/orgs/${GITHUB_USER}"
  OWNER_STATUS="$(api_status "${OWNER_URL}")"
fi

if [ "${OWNER_STATUS}" = "200" ]; then
  echo "Owner/user/org appears to exist."
else
  echo "Warning: could not confirm owner/user/org publicly via API."
  echo "Checked users + orgs endpoints for: ${GITHUB_USER}"
  echo "Continuing (normal for some networks or API limits)."
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
  if grep -A6 "^Host ${HOST_ALIAS}$" "${SSH_CONFIG}" 2>/dev/null | grep -q "IdentityFile ${SSH_KEY_PATH}"; then
    :
  else
    echo "Warning: existing Host ${HOST_ALIAS} may use a different IdentityFile than ${SSH_KEY_PATH}."
    echo "If git/ssh fails, remove that Host block from ${SSH_CONFIG} and re-run this script."
  fi
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

# GitHub SSH success messages vary slightly; keep patterns tight to avoid false positives.
if echo "${SSH_TEST_OUTPUT}" | grep -Eiq "successfully authenticated|authenticated as deploy key|You've successfully authenticated"; then
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
  echo "GitHub setup completed for: ${GITHUB_USER}/${REPO_NAME}"
  echo "=============================================="
  echo ""
  echo "Clone command:"
  echo "  git clone ${REMOTE_URL}"
  echo ""
  echo "If local repo already exists:"
  echo "  git remote set-url origin ${REMOTE_URL}"
  echo ""
  echo "If you use the standard staging pair, also run this script for the other private repo"
  echo "(staging_lamp_setup and staging_websites each need their own deploy key in GitHub)."
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
