#!/usr/bin/env bash
# deploy/scripts/helpers.sh
#
# shared helper functions

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"

# these are set by deploy.sh after loading settings.conf
run_log_file=""
dry_run="no"
verbose="no"

log_ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log_line() {
  local level="$1"
  shift
  local msg="$*"

  # always write to log file if configured
  if [ -n "${run_log_file}" ]; then
    printf '%s [%s] %s\n' "$(log_ts)" "${level}" "${msg}" >> "${run_log_file}"
  fi

  # stdout behavior depends on verbose, but errors always show
  if [ "${level}" = "error" ]; then
    printf '%s [%s] %s\n' "$(log_ts)" "${level}" "${msg}" >&2
  else
    if [ "${verbose}" = "yes" ]; then
      printf '%s [%s] %s\n' "$(log_ts)" "${level}" "${msg}"
    fi
  fi
}

info() { log_line "info" "$*"; }
warn() { log_line "warn" "$*"; }
error() { log_line "error" "$*"; }

die() {
  error "$*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing dependency: ${cmd}"
}

check_dependencies() {
  require_cmd git
  require_cmd rsync
  require_cmd awk
  require_cmd sed
  require_cmd grep
  require_cmd tar
  require_cmd date
  require_cmd mkdir
  require_cmd rm
  require_cmd mktemp
}

ensure_dir() {
  local d="$1"
  [ -n "${d}" ] || die "internal error: empty directory path"
  mkdir -p -- "${d}"
}

is_yes_no() {
  case "${1:-}" in
    yes|no) return 0 ;;
    *) return 1 ;;
  esac
}

safe_abs_path_or_die() {
  local p="$1"
  [ -n "${p}" ] || die "refusing empty path"
  case "${p}" in
    /*) ;;
    *) die "path must be absolute: ${p}" ;;
  esac
  case "${p}" in
    /) die "refusing to use path '/'"
       ;;
  esac
}

safe_sync_paths_or_die() {
  local src="$1"
  local dst="$2"

  [ -n "${src}" ] || die "refusing empty source path"
  [ -n "${dst}" ] || die "refusing empty destination path"

  # src may be under local_repo_path or a temp dir, so only check emptiness and dangerous values
  case "${src}" in
    /) die "refusing to use source '/'" ;;
  esac
  case "${dst}" in
    /) die "refusing to use destination '/'" ;;
  esac
}

run_cmd() {
  # runs a command, respecting dry_run for side-effect actions
  # usage: run_cmd <description> <command...>
  local desc="$1"
  shift

  if [ "${dry_run}" = "yes" ]; then
    info "dry_run: ${desc}: $*"
    return 0
  fi

  info "${desc}: $*"
  "$@"
}

run_cmd_always() {
  # runs command even in dry_run mode (use for safe reads like git fetch/ls-remote)
  local desc="$1"
  shift
  info "${desc}: $*"
  "$@"
}

acquire_lock() {
  local lock_file="$1"
  [ -n "${lock_file}" ] || die "internal error: empty lock file path"

  # lock file contains the pid; we use noclobber to create atomically
  ( set -o noclobber; printf '%s\n' "$$" > "${lock_file}" ) 2>/dev/null \
    || die "another deployment appears to be running (lock exists: ${lock_file})"
}

release_lock() {
  local lock_file="$1"
  [ -n "${lock_file}" ] || return 0
  rm -f -- "${lock_file}" 2>/dev/null || true
}

load_settings() {
  local settings_file="${repo_root}/deploy/config/settings.conf"
  [ -f "${settings_file}" ] || die "settings file not found: ${settings_file}"

  # shellcheck disable=SC1090
  . "${settings_file}"

  [ -n "${github_repo_ssh_url:-}" ] || die "missing github_repo_ssh_url in settings.conf"
  [ -n "${local_repo_path:-}" ] || die "missing local_repo_path in settings.conf"
  [ -n "${repo_default_branch:-}" ] || die "missing repo_default_branch in settings.conf"

  [ -n "${logs_dir:-}" ] || die "missing logs_dir in settings.conf"
  [ -n "${tmp_dir:-}" ] || die "missing tmp_dir in settings.conf"
  [ -n "${inventory_file:-}" ] || die "missing inventory_file in settings.conf"
  [ -n "${db_inventory_file:-}" ] || die "missing db_inventory_file in settings.conf"

  is_yes_no "${dry_run:-}" || die "dry_run must be yes/no (settings.conf)"
  is_yes_no "${verbose:-}" || die "verbose must be yes/no (settings.conf)"
  is_yes_no "${enable_delete:-}" || die "enable_delete must be yes/no (settings.conf)"
  is_yes_no "${create_live_dirs:-}" || die "create_live_dirs must be yes/no (settings.conf)"

  purge_inactive="${purge_inactive:-no}"
  is_yes_no "${purge_inactive}" || die "purge_inactive must be yes/no (settings.conf)"

  if [ -z "${ssh_db_identity_file+x}" ]; then
    ssh_db_identity_file="/root/.ssh/db_pull_ed25519"
  fi
  if [ -n "${ssh_db_identity_file}" ]; then
    safe_abs_path_or_die "${ssh_db_identity_file}"
  fi

  dry_run="${dry_run}"
  verbose="${verbose}"
}

