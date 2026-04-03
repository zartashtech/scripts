#!/usr/bin/env bash
# ssh_based_sql_dump_on_remote.sh
#
# SOURCE OF TRUTH: **staging_lamp_setup** (private) `github-public/ssh_based_sql_dump_on_remote.sh`
# PUBLISHING: copy into public repo **scripts** as `ssh_based_sql_dump_on_remote.sh` (repo root, `main`).
#
# Hardened for running on **production** after: `curl -fsSL … | …` — validate inputs, strict SSH client
# options, pipefail on dumps, explicit production confirmation. Does **not** verify the downloaded file
# against a checksum; pin/tag releases and verify out-of-band if you need supply-chain guarantees.
#
# Run **as root** on the **MySQL source** host only.
#
# Optional env:
#   DUMP_DIR_LOCAL   DUMP_DIR_REMOTE   SOURCE_MYSQL_CNF   REMOTE_MYSQL_CNF
#   SSH_STRICT_HOST_KEYS=yes  → StrictHostKeyChecking=yes (fail if host key unknown; pre-populate known_hosts)

set -euo pipefail
set -o noclobber

umask 077

DUMP_DIR_LOCAL="${DUMP_DIR_LOCAL:-/opt/deploy/sql_dump}"
DUMP_DIR_REMOTE="${DUMP_DIR_REMOTE:-/opt/deploy/sql_dump}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/remote_ssh}"
SOURCE_MYSQL_CNF="${SOURCE_MYSQL_CNF:-/root/.dump.conf}"
REMOTE_MYSQL_CNF="${REMOTE_MYSQL_CNF:-/root/.dump.conf}"

die() { echo "error: $*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
}

# Absolute path only; no .. ; no newlines/control chars; reject odd whitespace
validate_abs_path() {
  local p="$1" label="$2"
  [ -n "${p}" ] || die "${label}: empty path"
  [[ "${p}" == /* ]] || die "${label} must be absolute: ${p}"
  [[ "${p}" != *..* ]] || die "${label} must not contain ..: ${p}"
  [[ "${p}" != *$'\n'* && "${p}" != *$'\r'* ]] || die "${label} must not contain newlines"
  case "${p}" in
    *[[:cntrl:]]*) die "${label} contains control characters" ;;
  esac
}

# Paths used as scp remote target: user@host:path — no spaces or colons in path segment.
validate_scp_remote_path_segment() {
  local p="$1" label="$2"
  [[ "${p}" != *' '* && "${p}" != *$'\t'* ]] || die "${label} must not contain whitespace: ${p}"
  [[ "${p}" != *':'* ]] || die "${label} must not contain ':' (breaks scp remote path): ${p}"
}

ssh_host_key_opt() {
  if [ "${SSH_STRICT_HOST_KEYS:-}" = "yes" ]; then
    printf '%s' "StrictHostKeyChecking=yes"
  else
    printf '%s' "StrictHostKeyChecking=accept-new"
  fi
}

# Hostname (RFC conservative) or IPv4 literal. IPv6: not accepted here (avoid footguns on production).
validate_remote_host_candidate() {
  local h="$1"
  [ -n "${h}" ] || die "remote host empty"
  [[ "${h}" != *[![:print:]]* ]] || die "remote host contains non-printable characters"
  case "${h}" in
    *[\;\|\&\$\(\)\`\<\>\ \	]* ) die "remote host contains forbidden characters (use a plain hostname or IPv4)" ;;
  esac
  if [[ "${h}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    return 0
  fi
  if [[ "${h}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]] || [[ "${h}" =~ ^[a-zA-Z0-9]$ ]]; then
    return 0
  fi
  die "remote host must be a hostname (letters, digits, ., -) or IPv4, got: ${h}"
}

validate_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]] || die "SSH port must be numeric: ${p}"
  [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ] || die "SSH port out of range: ${p}"
}

validate_remote_user() {
  local u="$1"
  [ -n "${u}" ] || die "SSH user empty"
  [[ "${u}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "SSH user must be a safe POSIX-like name (not empty, max 32, [a-z_][a-z0-9_-]*)"
}

# MySQL unquoted identifier style (letters, digits, _) — avoids injection via backticks/options
validate_db_name() {
  local d="$1"
  [ -n "${d}" ] || die "database name empty"
  [[ "${d}" =~ ^[a-zA-Z0-9_]+$ ]] || die "database name must match ^[a-zA-Z0-9_]+$ (no spaces or punctuation): ${d}"
  [ "${#d}" -le 64 ] || die "database name too long (max 64)"
}

validate_dump_basename() {
  local b="$1"
  [[ "${b}" =~ ^[a-zA-Z0-9_]+\.sql\.gz$ ]] || die "internal error: bad dump basename: ${b}"
}

run_text_editor() {
  local path="$1"
  if command -v nano >/dev/null 2>&1; then
    nano "${path}" || die "editor (nano) exited with error"
  elif command -v vim >/dev/null 2>&1; then
    vim "${path}" || die "editor (vim) exited with error"
  elif command -v vi >/dev/null 2>&1; then
    vi "${path}" || die "editor (vi) exited with error"
  else
    die "install nano, vim, or vi — EDITOR is not honored in strict mode"
  fi
}

ssh_exec() {
  # shellcheck disable=SC2086
  ssh -i "${SSH_KEY}" -p "${REMOTE_PORT}" \
    -o ConnectTimeout=15 \
    -o "$(ssh_host_key_opt)" \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o LogLevel=ERROR \
    -o BatchMode=yes \
    -- "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

ssh_exec_tty() {
  ssh -t -i "${SSH_KEY}" -p "${REMOTE_PORT}" \
    -o ConnectTimeout=15 \
    -o "$(ssh_host_key_opt)" \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o LogLevel=ERROR \
    -- "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

dump_conf_template() {
  printf '%s\n' '[client]' 'user=root' 'password=' 'host=127.0.0.1'
}

ensure_local_dump_conf() {
  local f="$1"
  if [ -f "${f}" ] && [ -s "${f}" ]; then
    echo "using existing ${f} on this host"
    return 0
  fi

  echo ""
  echo "=== ${f} is missing or empty on this host ==="
  echo "creating a template — set MySQL user, password, host for the DATABASE YOU ARE DUMPING; save and exit."
  dump_conf_template >|"${f}"
  chmod 600 "${f}"
  run_text_editor "${f}"
  [ -f "${f}" ] || die "${f} missing after editor"
  [ -s "${f}" ] || die "${f} is still empty — add [client] credentials and re-run"
}

ensure_remote_dump_conf() {
  local rf="$1"
  local sq
  sq="$(printf '%q' "${rf}")"

  if ssh_exec "test -f ${sq} && test -s ${sq}" 2>/dev/null; then
    echo "using existing ${rf} on ${REMOTE_HOST}"
    return 0
  fi

  echo ""
  echo "=== ${rf} is missing or empty on ${REMOTE_HOST} ==="
  echo "creating template — set MySQL user/password/host for IMPORT on staging; save and exit nano."
  ssh_exec "umask 077; printf '%s\\n' '[client]' 'user=root' 'password=' 'host=127.0.0.1' > ${sq} && chmod 600 ${sq}" \
    || die "could not create ${rf} on remote"

  ssh_exec_tty "nano ${sq}" \
    || die "nano on remote failed (install nano on ${REMOTE_HOST} or edit ${rf} manually)"

  ssh_exec "test -f ${sq} && test -s ${sq}" \
    || die "${rf} on ${REMOTE_HOST} is still missing or empty"
}

prompt_nonempty() {
  local msg="$1"
  local val=""
  while [ -z "${val}" ]; do
    read -r -p "${msg}" val || die "stdin closed"
    val="$(echo "${val}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  done
  printf '%s' "${val}"
}

prompt_optional_default() {
  local msg="$1" default="$2" val
  read -r -p "${msg} [${default}]: " val || die "stdin closed"
  val="$(echo "${val}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "${val}" ]; then
    printf '%s' "${default}"
  else
    printf '%s' "${val}"
  fi
}

ssh_test() {
  ssh_exec "echo ok" >/dev/null 2>&1
}

ensure_remote_ssh_key() {
  local pub="${SSH_KEY}.pub"
  mkdir -p -- "$(dirname "${SSH_KEY}")"
  if [ ! -f "${SSH_KEY}" ] || [ ! -f "${pub}" ]; then
    echo "creating SSH key pair: ${SSH_KEY}"
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "remote_ssh_staging $(date -u +%Y%m%dT%H%MZ)"
    chmod 600 "${SSH_KEY}"
    chmod 644 "${pub}"
  fi
  echo ""
  echo "=== add this ONE line to ${REMOTE_USER}@${REMOTE_HOST} authorized_keys ==="
  echo ""
  cat -- "${pub}"
  echo ""
  echo "=== end public key ==="
  echo ""
}

production_confirm_host() {
  local again
  echo ""
  echo ">>> PRODUCTION / DESTRUCTIVE REMOTE: this will overwrite ${DUMP_DIR_REMOTE} on ${REMOTE_HOST} and import into MySQL there."
  read -r -p "Type the staging hostname/IP again EXACTLY to confirm: " again || die "stdin closed"
  again="$(echo "${again}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ "${again}" = "${REMOTE_HOST}" ] || die "confirmation did not match host (${again} != ${REMOTE_HOST}) — aborting"
}

mysql_local_test_cnf() {
  local db="$1" cnf="$2"
  mysql --defaults-file="${cnf}" -e "USE \`${db}\`; SELECT 1" >/dev/null 2>&1
}

mysql_local_dump_cnf() {
  local db="$1" cnf="$2" out="$3"
  mysqldump --defaults-file="${cnf}" \
    --single-transaction --routines --triggers --events --set-gtid-purged=OFF \
    --databases "${db}" | gzip -c >|"${out}"
}

remote_prepare_and_upload() {
  local dump_basename="$1" local_path="$2"
  validate_dump_basename "${dump_basename}"

  ssh_exec "mkdir -p -- $(printf '%q' "${DUMP_DIR_REMOTE}") && rm -f -- $(printf '%q' "${DUMP_DIR_REMOTE}")/*" \
    || die "could not prepare ${DUMP_DIR_REMOTE} on remote"

  scp -i "${SSH_KEY}" -P "${REMOTE_PORT}" \
    -o ConnectTimeout=15 \
    -o "$(ssh_host_key_opt)" \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o LogLevel=ERROR \
    -- "${local_path}" "${REMOTE_USER}@${REMOTE_HOST}:${DUMP_DIR_REMOTE}/${dump_basename}" \
    || die "scp failed"
}

remote_import_dump() {
  local dump_basename="$1"
  validate_dump_basename "${dump_basename}"

  local rf_q df_q
  rf_q="$(printf '%q' "${DUMP_DIR_REMOTE}/${dump_basename}")"
  if [ -n "${REMOTE_MYSQL_CNF}" ]; then
    df_q="$(printf '%q' "${REMOTE_MYSQL_CNF}")"
    ssh_exec "set -euo pipefail; f=${rf_q}; [ -f \"\${f}\" ] || exit 1; gzip -dc -- \"\${f}\" | mysql --defaults-file=${df_q}" \
      || return 1
  else
    ssh_exec "set -euo pipefail; f=${rf_q}; [ -f \"\${f}\" ] || exit 1; gzip -dc -- \"\${f}\" | mysql" \
      || return 1
  fi
  return 0
}

remote_rm_dump() {
  local dump_basename="$1"
  validate_dump_basename "${dump_basename}"
  local rf_q
  rf_q="$(printf '%q' "${DUMP_DIR_REMOTE}/${dump_basename}")"
  ssh_exec "rm -f -- ${rf_q}" 2>/dev/null || true
}

main() {
  require_root

  command -v ssh >/dev/null 2>&1 || die "ssh not found"
  command -v scp >/dev/null 2>&1 || die "scp not found"
  command -v mysql >/dev/null 2>&1 || die "mysql client not found"
  command -v mysqldump >/dev/null 2>&1 || die "mysqldump not found"
  command -v gzip >/dev/null 2>&1 || die "gzip not found"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
  command -v sed >/dev/null 2>&1 || die "sed not found"

  validate_abs_path "${DUMP_DIR_LOCAL}" "DUMP_DIR_LOCAL"
  validate_abs_path "${DUMP_DIR_REMOTE}" "DUMP_DIR_REMOTE"
  validate_scp_remote_path_segment "${DUMP_DIR_REMOTE}" "DUMP_DIR_REMOTE"
  validate_abs_path "${SOURCE_MYSQL_CNF}" "SOURCE_MYSQL_CNF"
  [ -n "${REMOTE_MYSQL_CNF}" ] && validate_abs_path "${REMOTE_MYSQL_CNF}" "REMOTE_MYSQL_CNF"

  echo "=== staging / remote SSH (where the dump will be uploaded and imported) ==="
  REMOTE_HOST="$(prompt_nonempty 'remote server host (hostname or IPv4 only): ')"
  validate_remote_host_candidate "${REMOTE_HOST}"

  REMOTE_PORT="$(prompt_optional_default 'remote server SSH port' '22')"
  validate_port "${REMOTE_PORT}"

  REMOTE_USER="$(prompt_optional_default 'remote SSH username' 'root')"
  validate_remote_user "${REMOTE_USER}"

  production_confirm_host

  echo "testing SSH to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT} ..."
  if ! ssh_test; then
    echo "SSH failed (no key or not authorized yet)."
    ensure_remote_ssh_key
    while true; do
      read -r -p "Have you placed the public key on the remote server? [Y/n]: " ok || die "stdin closed"
      ok="$(echo "${ok}" | tr '[:upper:]' '[:lower:]')"
      if [ -z "${ok}" ] || [ "${ok}" = "y" ] || [ "${ok}" = "yes" ]; then
        break
      fi
      echo "Place the key for user ${REMOTE_USER}, then press Enter (or y)."
    done
    if ! ssh_test; then
      die "still cannot SSH to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT} — check key, user, port, firewall"
    fi
  fi
  echo "SSH ok."

  if [ -n "${REMOTE_MYSQL_CNF}" ]; then
    ensure_remote_dump_conf "${REMOTE_MYSQL_CNF}"
  fi

  echo ""
  ensure_local_dump_conf "${SOURCE_MYSQL_CNF}"

  echo ""
  echo "=== local MySQL (this server — data source) ==="
  echo "using ${SOURCE_MYSQL_CNF} (--defaults-file) for local mysqldump"
  DB_NAME="$(prompt_nonempty 'local database name to dump: ')"
  validate_db_name "${DB_NAME}"

  while true; do
    echo "validating local MySQL access ..."
    if mysql_local_test_cnf "${DB_NAME}" "${SOURCE_MYSQL_CNF}"; then
      echo "local MySQL ok."
      break
    fi
    echo "cannot connect or cannot USE database (check ${SOURCE_MYSQL_CNF} and grants)."
    echo "  1) Retry (new database name)"
    echo "  2) Re-edit ${SOURCE_MYSQL_CNF} and retry"
    echo "  3) Exit"
    read -r -p "choose [1/2/3]: " pick || die "stdin closed"
    case "${pick}" in
      1)
        DB_NAME="$(prompt_nonempty 'local database name to dump: ')"
        validate_db_name "${DB_NAME}"
        ;;
      2)
        run_text_editor "${SOURCE_MYSQL_CNF}"
        [ -s "${SOURCE_MYSQL_CNF}" ] || die "${SOURCE_MYSQL_CNF} empty"
        ;;
      3) exit 1 ;;
      *) echo "invalid choice" ;;
    esac
  done

  mkdir -p -- "${DUMP_DIR_LOCAL}"
  DUMP_BASENAME="${DB_NAME}.sql.gz"
  validate_dump_basename "${DUMP_BASENAME}"
  LOCAL_DUMP="${DUMP_DIR_LOCAL}/${DUMP_BASENAME}"

  if [ -e "${LOCAL_DUMP}" ]; then
    echo "removing existing ${LOCAL_DUMP}"
    rm -f -- "${LOCAL_DUMP}"
  fi

  echo "creating dump ${LOCAL_DUMP} ..."
  mysql_local_dump_cnf "${DB_NAME}" "${SOURCE_MYSQL_CNF}" "${LOCAL_DUMP}"
  [ -s "${LOCAL_DUMP}" ] || die "dump file empty or missing"

  if [ -n "${REMOTE_MYSQL_CNF}" ]; then
    echo "remote import will use: mysql --defaults-file=${REMOTE_MYSQL_CNF}"
  fi

  echo "preparing remote ${DUMP_DIR_REMOTE} (clear + upload) ... — ALL FILES IN THAT DIRECTORY ON STAGING WILL BE REMOVED"
  remote_prepare_and_upload "${DUMP_BASENAME}" "${LOCAL_DUMP}"

  echo "importing on remote via mysql ..."
  if ! remote_import_dump "${DUMP_BASENAME}"; then
    echo "error: import on remote failed — dump may still exist on remote at ${DUMP_DIR_REMOTE}/${DUMP_BASENAME}" >&2
    remote_rm_dump "${DUMP_BASENAME}"
    rm -f -- "${LOCAL_DUMP}" 2>/dev/null || true
    die "database import failed on staging"
  fi

  echo "removing dump on remote ..."
  remote_rm_dump "${DUMP_BASENAME}"

  echo "removing dump on local ..."
  rm -f -- "${LOCAL_DUMP}"

  echo ""
  echo "=== database successfully exported and imported on ${REMOTE_HOST} ==="
}

main "$@"
