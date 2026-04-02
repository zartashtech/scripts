#!/usr/bin/env bash
# deploy/scripts/cleanup_inactive_sites.sh
#
# when purge_inactive=yes in settings.conf:
#
# 1) inventory: active=no
#    - remove Let's Encrypt cert (best effort) for that site's domain
#    - a2dissite + remove managed vhost(s) for that website_id (+ certbot ssl snippets if present)
#    - rm -rf /home/<website_id>
#
# 2) orphans: apache vhost file /etc/apache2/sites-available/<id>.conf exists but <id> is not
#    listed in site_inventory.ini at all (site removed from inventory)
#    - same cleanup; domain read from ServerName in the vhost file
#
# skips: vhost names not matching managed id pattern (e.g. 000-default), and default-ssl
#
# does NOT remove mysql data (db_inventory.ini). does NOT delete random /home/* dirs without
# a matching managed vhost or inventory inactive row (avoids touching e.g. /home/ubuntu).
#
# respects dry_run=yes

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/helpers.sh"

# bash 4+ associative array: ids that appear anywhere in site_inventory.ini
declare -A INV_IDS=()

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run as root (use sudo)"
  fi
}

verify_site_home_or_die() {
  local website_id="$1"
  local site_home="$2"
  local expected="/home/${website_id}"
  if [ "${site_home}" != "${expected}" ]; then
    die "refusing purge: site_home mismatch (expected ${expected}, got ${site_home})"
  fi
  safe_abs_path_or_die "${site_home}"
}

servername_from_vhost() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk '/^[[:space:]]*ServerName[[:space:]]+/ { print $2; exit }' "$f" | tr -d '\r'
}

remove_certbot_cert() {
  local domain="$1"
  [ -n "${domain}" ] || return 0
  if ! command -v certbot >/dev/null 2>&1; then
    warn "certbot not installed; skip cert delete for domain=${domain}"
    return 0
  fi
  if [ "${dry_run}" = "yes" ]; then
    info "dry_run: would certbot delete --cert-name ${domain}"
    return 0
  fi
  if certbot delete --cert-name "${domain}" --non-interactive >> "${run_log_file}" 2>&1; then
    info "certbot deleted certificate name=${domain}"
  else
    warn "certbot delete failed or no cert named ${domain} (often safe to ignore)"
  fi
}

remove_vhost_file() {
  local conf_basename="$1"
  local path="/etc/apache2/sites-available/${conf_basename}"

  if [ "${dry_run}" = "yes" ]; then
    info "dry_run: would a2dissite ${conf_basename} and rm ${path}"
    return 0
  fi

  if command -v a2dissite >/dev/null 2>&1; then
    a2dissite "${conf_basename}" 2>/dev/null || true
  fi
  if [ -e "${path}" ]; then
    rm -f -- "${path}"
    info "removed vhost ${path}"
  fi
}

# primary vhost + typical certbot apache ssl companion
remove_apache_site_config() {
  local website_id="$1"
  local domain="$2"

  remove_vhost_file "${website_id}.conf"

  if [ -n "${domain}" ]; then
    remove_vhost_file "${domain}-le-ssl.conf"
  fi
  remove_vhost_file "${website_id}-le-ssl.conf"
}

remove_site_home() {
  local website_id="$1"
  local site_home="$2"

  verify_site_home_or_die "${website_id}" "${site_home}"

  if [ ! -d "${site_home}" ] && [ ! -e "${site_home}" ]; then
    info "purge: nothing to remove at ${site_home} (website_id=${website_id})"
    return 0
  fi

  if [ "${dry_run}" = "yes" ]; then
    info "dry_run: would rm -rf -- ${site_home} (website_id=${website_id})"
    return 0
  fi

  info "purge: removing site data ${site_home} (website_id=${website_id})"
  rm -rf -- "${site_home}"
}

# full teardown for one managed id (inactive in inventory or orphan vhost)
purge_site() {
  local website_id="$1"
  local domain="${2:-}"
  local site_home="/home/${website_id}"

  info "purge site website_id=${website_id} domain=${domain:-unknown}"

  local vhost_path="/etc/apache2/sites-available/${website_id}.conf"
  if [ -z "${domain}" ] && [ -f "${vhost_path}" ]; then
    domain="$(servername_from_vhost "${vhost_path}")"
  fi

  remove_certbot_cert "${domain}"
  remove_apache_site_config "${website_id}" "${domain}"
  remove_site_home "${website_id}" "${site_home}"
}

reserved_vhost_id() {
  local id="$1"
  case "${id}" in
    default-ssl) return 0 ;;
  esac
  return 1
}

managed_id_pattern() {
  local id="$1"
  [[ "${id}" =~ ^[a-z][a-z0-9_-]*$ ]]
}

build_inv_id_set() {
  INV_IDS=()
  local inv_path="$1"
  while IFS=$'\t' read -r website_id _d _r _s _doc _br _ac _sl _em; do
    [ -n "${website_id}" ] || continue
    INV_IDS["${website_id}"]=1
  done < <(bash "${script_dir}/read_inventory.sh" "${inv_path}")
}

main() {
  require_root

  load_settings

  local inv_path="${1:-}"
  if [ -z "${inv_path}" ]; then
    inv_path="${repo_root}/${inventory_file}"
  fi

  require_cmd apache2ctl
  require_cmd systemctl

  if [ -z "${run_log_file:-}" ]; then
    ensure_dir "${repo_root}/${logs_dir}"
    run_log_file="${repo_root}/${logs_dir}/cleanup-$(date +"%Y%m%d-%H%M%S").log"
  fi

  run_cmd_always "validate inventory (cleanup pass)" bash "${script_dir}/validate_inventory.sh" "${inv_path}"

  if [ "${purge_inactive}" != "yes" ]; then
    info "purge_inactive=no: skipping cleanup (set purge_inactive=yes in settings.conf)"
    return 0
  fi

  build_inv_id_set "${inv_path}"

  # --- 1) explicit inactive rows ---
  while IFS=$'\t' read -r website_id domain _repo _sh _doc _branch active _ssl _email; do
    [ -n "${website_id}" ] || continue
    if [ "${active}" != "yes" ]; then
      purge_site "${website_id}" "${domain}"
    fi
  done < <(bash "${script_dir}/read_inventory.sh" "${inv_path}")

  # --- 2) orphan vhosts: conf exists, id not in inventory ---
  local id dom f
  shopt -s nullglob
  for f in /etc/apache2/sites-available/*.conf; do
    id="$(basename "${f}" .conf)"
    reserved_vhost_id "${id}" && continue
    managed_id_pattern "${id}" || continue
    if [[ -n "${INV_IDS[${id}]+x}" ]]; then
      continue
    fi
    dom="$(servername_from_vhost "${f}")"
    info "cleanup orphan vhost (not in inventory) website_id=${id} servername=${dom}"
    purge_site "${id}" "${dom}"
  done
  shopt -u nullglob

  if [ "${dry_run}" != "yes" ]; then
    systemctl reload apache2 2>/dev/null || true
  fi

  info "site cleanup finished"
}

main "$@"
