#!/usr/bin/env bash
# deploy/scripts/ssh_db_bootstrap.sh
#
# staging server: one ed25519 key for every [source:*] in db_inventory.ini (db pulls).
# - creates ssh_db_identity_file if missing
# - tests ssh BatchMode to each source
# - on failure, prints pubkey + path to deploy/scripts/remote_ssh_connect_provision.sh
#
# run as root on staging:
#   sudo bash deploy/scripts/ssh_db_bootstrap.sh

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/helpers.sh"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run as root (use sudo)"
  fi
}

ensure_db_pull_key() {
  local key_path="$1"

  safe_abs_path_or_die "${key_path}"
  local pub="${key_path}.pub"
  local keydir
  keydir="$(dirname -- "${key_path}")"
  ensure_dir "${keydir}"
  chmod 700 "${keydir}" 2>/dev/null || true

  if [ -f "${key_path}" ]; then
    info "ssh key already exists: ${key_path}"
    return 0
  fi

  info "creating new ed25519 key: ${key_path}"
  ssh-keygen -t ed25519 -N "" -f "${key_path}" -C "staging-db-pull-$(hostname -s 2>/dev/null || echo staging)"
  chmod 600 "${key_path}"
  chmod 644 "${pub}"
  info "created ${key_path}"
}

test_one_source() {
  local name="$1"
  local host="$2"
  local user="$3"
  local port="$4"
  local key_path="$5"

  local -a ssh_args
  ssh_args=(-p "${port}" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
  if [ -n "${key_path}" ] && [ -f "${key_path}" ]; then
    ssh_args+=(-i "${key_path}" -o IdentitiesOnly=yes)
  fi

  if ssh "${ssh_args[@]}" -- "${user}@${host}" "echo ok" >/dev/null 2>&1; then
    info "ssh ok  source=${name} target=${user}@${host}:${port}"
    return 0
  fi
  warn "ssh FAIL source=${name} target=${user}@${host}:${port}"
  return 1
}

main() {
  require_root
  load_settings

  require_cmd ssh
  require_cmd ssh-keygen

  local db_inv="${repo_root}/${db_inventory_file}"
  [ -f "${db_inv}" ] || die "db inventory not found: ${db_inv}"

  run_cmd_always "validate db inventory" bash "${script_dir}/validate_db_inventory.sh" "${db_inv}"

  local key_path="${ssh_db_identity_file:-}"
  if [ -z "${key_path}" ]; then
    die "ssh_db_identity_file is empty in settings.conf; set a path for the shared db-pull key"
  fi

  ensure_db_pull_key "${key_path}"

  info "testing ssh to each [source:*] in ${db_inventory_file}"

  local failed=0
  while IFS=$'\t' read -r typ name host user port _m _s; do
    [ "${typ}" = "source" ] || continue
    test_one_source "${name}" "${host}" "${user}" "${port}" "${key_path}" || failed=1
  done < <(bash "${script_dir}/read_db_inventory.sh" "${db_inv}")

  if [ "${failed}" -eq 0 ]; then
    info "all sources reachable via ssh with ${key_path}"
    return 0
  fi

  warn "install the public key on failed hosts (same linux user as ssh_user in each [source:*])"
  echo ""
  echo "=== public key (one line) ==="
  cat -- "${key_path}.pub"
  echo ""
  echo "=== on each source server ==="
  echo "copy deploy/scripts/remote_ssh_connect_provision.sh to the server, then:"
  echo "  sudo bash remote_ssh_connect_provision.sh"
  echo "choose the same user as ssh_user in [source:*], paste ONE line of public key above."
  echo "non-interactive: printf '%s\n' \"\$(cat staging.pub)\" | TARGET_USER=root sudo -E bash remote_ssh_connect_provision.sh"
  echo ""
  return 1
}

main "$@"
