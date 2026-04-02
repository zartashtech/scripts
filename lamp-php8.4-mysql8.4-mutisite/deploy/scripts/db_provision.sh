#!/usr/bin/env bash
# deploy/scripts/db_provision.sh
#
# provisions shared databases on staging using db_inventory.ini:
# - creates local dbs/users (if db_create=yes)
# - imports data from live servers via ssh + mysqldump (based on [map:*] sections)
#
# design:
# - one db inventory drives everything
# - websites can share dbs without duplicating config
#
# security:
# - no mysql passwords in inventory
# - expects /root/.my.cnf on staging for local mysql auth
# - expects live server has /root/.my.cnf and ssh user can run mysqldump via sudo

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/helpers.sh"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run as root (use sudo)"
  fi
}

create_local_db_users() {
  local local_name="$1"
  local db_name="$2"
  local db_host="$3"
  local users_csv="$4"
  local db_create="$5"

  if [ "${db_create}" != "yes" ]; then
    info "db: skip db_create for local_db=${local_name}"
    return 0
  fi

  warn "db: creating database + mysql user(s) for local_db=${local_name} (change passwords after run)"

  run_cmd_always "mysql create database" mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

  local u
  while IFS= read -r u; do
    [ -n "${u}" ] || continue
    # each user gets full privileges on this db (staging default); tighten grants manually if you need read-only users
    run_cmd_always "mysql create user ${u}" mysql -e "CREATE USER IF NOT EXISTS '${u}'@'${db_host}' IDENTIFIED BY 'change_me_${local_name}_${u}';"
    run_cmd_always "mysql grant ${u}" mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${u}'@'${db_host}'; FLUSH PRIVILEGES;"
  done < <(printf '%s' "${users_csv}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d')
}

import_map() {
  local map_name="$1"
  local enabled="$2"
  local local_db_key="$3"
  local source_name="$4"
  local source_db="$5"
  local ssh_host="$6"
  local ssh_user="$7"
  local ssh_port="$8"
  local mysql_defaults_file="$9"
  local sudo_mysqldump="${10}"
  local dest_mysql_db="${11}"

  if [ "${enabled}" != "yes" ]; then
    info "db: skip disabled map=${map_name}"
    return 0
  fi

  [ -n "${local_db_key}" ] || die "db: empty local_db for map=${map_name}"
  [ -n "${dest_mysql_db}" ] || die "db: empty dest mysql database name for map=${map_name}"
  [ -n "${source_db}" ] || die "db: empty source_db for map=${map_name}"
  [ -n "${ssh_host}" ] || die "db: missing ssh_host for source=${source_name}"
  [ -n "${ssh_user}" ] || die "db: missing ssh_user for source=${source_name}"
  [ -n "${ssh_port}" ] || die "db: missing ssh_port for source=${source_name}"
  [ -n "${mysql_defaults_file}" ] || mysql_defaults_file="/root/.my.cnf"
  if [ -z "${sudo_mysqldump}" ]; then sudo_mysqldump="yes"; fi

  local ssh_target="${ssh_user}@${ssh_host}"

  local prefix=""
  if [ "${sudo_mysqldump}" = "yes" ]; then
    prefix="sudo "
  fi

  local remote_cmd
  remote_cmd="${prefix}mysqldump --defaults-extra-file=${mysql_defaults_file} --single-transaction --routines --triggers --events --set-gtid-purged=OFF --databases \"${source_db}\""

  if [ "${dry_run}" = "yes" ]; then
    info "dry_run: db import map=${map_name} source=${ssh_target}:${ssh_port}/${source_db} local_db=${local_db_key} dest_mysql_db=${dest_mysql_db}"
    return 0
  fi

  info "db import start map=${map_name} source=${ssh_target}:${ssh_port}/${source_db} local_db=${local_db_key} dest_mysql_db=${dest_mysql_db}"

  local -a ssh_base
  ssh_base=(-p "${ssh_port}" -o BatchMode=yes -o ConnectTimeout=30)
  if [ -n "${ssh_db_identity_file:-}" ]; then
    if [ ! -f "${ssh_db_identity_file}" ]; then
      die "ssh key not found: ${ssh_db_identity_file} (run: sudo bash deploy/scripts/ssh_db_bootstrap.sh)"
    fi
    ssh_base+=(-i "${ssh_db_identity_file}" -o IdentitiesOnly=yes)
  fi

  ssh "${ssh_base[@]}" -- "${ssh_target}" "${remote_cmd}" \
    | mysql "${dest_mysql_db}" >> "${run_log_file}" 2>&1 \
    || die "db import failed map=${map_name}"

  info "db import success map=${map_name} dest_mysql_db=${dest_mysql_db}"
}

main() {
  require_root
  load_settings
  check_dependencies

  require_cmd mysql
  require_cmd ssh

  local db_inv="${repo_root}/${db_inventory_file}"
  [ -f "${db_inv}" ] || die "db inventory not found: ${db_inv}"

  ensure_dir "${repo_root}/${logs_dir}"
  ensure_dir "${repo_root}/${tmp_dir}"

  local ts
  ts="$(date +"%Y%m%d-%H%M%S")"
  run_log_file="${repo_root}/${logs_dir}/db-${ts}.log"

  info "start db provisioning run_id=${ts}"
  run_cmd_always "validate db inventory" bash "${script_dir}/validate_db_inventory.sh" "${db_inv}"

  local parsed
  parsed="$(bash "${script_dir}/read_db_inventory.sh" "${db_inv}")"

  declare -A local_db_to_dbname

  # first pass: local dbs (+ all mysql users listed for each db)
  while IFS=$'\t' read -r type name db_name db_host users_csv db_create; do
    if [ "${type}" = "local" ]; then
      local_db_to_dbname["${name}"]="${db_name}"
      create_local_db_users "${name}" "${db_name}" "${db_host}" "${users_csv}" "${db_create}"
    fi
  done <<< "${parsed}"

  # build associative maps for sources
  declare -A src_host src_user src_port src_defaults src_sudo
  while IFS=$'\t' read -r type name ssh_host ssh_user ssh_port mysql_defaults_file sudo_mysqldump; do
    if [ "${type}" = "source" ]; then
      src_host["${name}"]="${ssh_host}"
      src_user["${name}"]="${ssh_user}"
      src_port["${name}"]="${ssh_port}"
      src_defaults["${name}"]="${mysql_defaults_file}"
      src_sudo["${name}"]="${sudo_mysqldump}"
    fi
  done <<< "${parsed}"

  # second pass: maps (imports) — mysql target is db_name from [local_db:*], not the section label
  while IFS=$'\t' read -r type map_name enabled local_db source source_db; do
    if [ "${type}" = "map" ]; then
      local dest_mysql_db="${local_db_to_dbname[${local_db}]:-}"
      [ -n "${dest_mysql_db}" ] || die "db: map ${map_name}: local_db=${local_db} has no matching [local_db:${local_db}]"
      import_map \
        "${map_name}" \
        "${enabled}" \
        "${local_db}" \
        "${source}" \
        "${source_db}" \
        "${src_host[${source}]:-}" \
        "${src_user[${source}]:-}" \
        "${src_port[${source}]:-}" \
        "${src_defaults[${source}]:-}" \
        "${src_sudo[${source}]:-}" \
        "${dest_mysql_db}"
    fi
  done <<< "${parsed}"

  info "db provisioning finished log_file=${run_log_file}"
}

main "$@"

