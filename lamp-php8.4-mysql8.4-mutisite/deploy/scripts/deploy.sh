#!/usr/bin/env bash
# deploy/scripts/deploy.sh
#
# main entrypoint:
# - loads settings
# - validates inventory
# - syncs the private repo
# - deploys only active=yes sites
#
# safety:
# - uses a lock file to avoid concurrent runs
# - refuses dangerous paths

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "${script_dir}/helpers.sh"

usage() {
  cat <<'EOF'
usage:
  bash deploy/scripts/deploy.sh [options]

options:
  --site <website_id>      deploy only one website_id
  --inventory <path>       use a custom site_inventory.ini path
  --verbose                print more output to stdout
  --help                   show help

configuration:
  edit deploy/config/settings.conf
EOF
}

parse_args() {
  site_filter=""
  inventory_override=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --site)
        site_filter="${2:-}"
        [ -n "${site_filter}" ] || die "--site requires a website_id"
        shift 2
        ;;
      --inventory)
        inventory_override="${2:-}"
        [ -n "${inventory_override}" ] || die "--inventory requires a path"
        shift 2
        ;;
      --verbose)
        verbose="yes"
        shift 1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  load_settings

  check_dependencies

  local inv_path="${repo_root}/${inventory_file}"
  if [ -n "${inventory_override}" ]; then
    if [[ "${inventory_override}" == /* ]]; then
      inv_path="${inventory_override}"
    else
      inv_path="${repo_root}/${inventory_override}"
    fi
  fi

  # prepare dirs (relative paths from settings are relative to repo_root)
  local logs_path="${repo_root}/${logs_dir}"
  local tmp_path="${repo_root}/${tmp_dir}"
  ensure_dir "${logs_path}"
  ensure_dir "${tmp_path}"

  local ts
  ts="$(date +"%Y%m%d-%H%M%S")"
  run_log_file="${logs_path}/deploy-${ts}.log"

  local lock_file="${tmp_path}/deploy.lock"
  acquire_lock "${lock_file}"
  # shellcheck disable=SC2064
  trap 'release_lock "${lock_file}"' EXIT

  info "start deployment run_id=${ts}"
  info "repo_root=${repo_root}"
  info "inventory=${inv_path}"
  info "dry_run=${dry_run} enable_delete=${enable_delete} purge_inactive=${purge_inactive}"

  # validate inventory
  run_cmd_always "validate inventory" bash "${script_dir}/validate_inventory.sh" "${inv_path}"

  # remove vhosts + site dirs for active=no (if purge_inactive=yes in settings.conf)
  bash "${script_dir}/cleanup_inactive_sites.sh" "${inv_path}"

  # sync repo (clone/fetch)
  run_cmd_always "sync repo" bash "${script_dir}/sync_repo.sh" "${github_repo_ssh_url}" "${local_repo_path}" "${repo_default_branch}"

  # validate exclude file if set
  if [ -n "${exclude_file:-}" ] && [ ! -f "${exclude_file}" ]; then
    die "exclude_file set but not found: ${exclude_file}"
  fi

  # loop active sites
  info "reading inventory and deploying active sites"

  local deployed_count=0
  local skipped_count=0

  # ini reader prints tab-separated lines
  while IFS=$'\t' read -r website_id domain repo_folder site_home docroot_subdir branch active ssl certbot_email; do
    [ -n "${website_id}" ] || continue

    if [ "${active}" != "yes" ]; then
      info "skip inactive website_id=${website_id}"
      skipped_count=$((skipped_count+1))
      continue
    fi

    if [ -n "${site_filter}" ] && [ "${website_id}" != "${site_filter}" ]; then
      info "skip due to --site filter website_id=${website_id}"
      skipped_count=$((skipped_count+1))
      continue
    fi

    # deploy one site (code only)
    bash "${script_dir}/deploy_site.sh" \
      "${local_repo_path}" \
      "${tmp_path}" \
      "${website_id}" \
      "${domain}" \
      "${repo_folder}" \
      "${site_home}/${docroot_subdir}" \
      "${branch}" \
      "${enable_delete}" \
      "${create_live_dirs}" \
      "${rsync_base_opts}" \
      "${exclude_file:-}"

    deployed_count=$((deployed_count+1))
  done < <(bash "${script_dir}/read_inventory.sh" "${inv_path}")

  info "deployment run finished"
  info "log_file=${run_log_file}"
}

main "$@"

