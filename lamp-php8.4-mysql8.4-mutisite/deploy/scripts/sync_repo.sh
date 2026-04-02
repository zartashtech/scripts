#!/usr/bin/env bash
# deploy/scripts/sync_repo.sh
#
# clones the private websites repo if missing, otherwise fetches updates.
# keeps a local copy at a fixed path for future resync.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "${script_dir}/helpers.sh"

sync_repo() {
  local github_repo_ssh_url="$1"
  local local_repo_path="$2"
  local repo_default_branch="$3"

  [ -n "${github_repo_ssh_url}" ] || die "github_repo_ssh_url is empty (check settings.conf)"
  safe_abs_path_or_die "${local_repo_path}"
  [ -n "${repo_default_branch}" ] || die "repo_default_branch is empty (check settings.conf)"

  # quick auth check (helps beginners)
  info "testing repo access (git ls-remote)"
  if ! run_cmd_always "git ls-remote" git ls-remote "${github_repo_ssh_url}" >/dev/null 2>&1; then
    die "git cannot access private repo. configure ssh auth/deploy key, then retry. url=${github_repo_ssh_url}"
  fi

  if [ ! -d "${local_repo_path}/.git" ]; then
    info "local repo not found, cloning"
    ensure_dir "$(dirname -- "${local_repo_path}")"
    run_cmd "git clone" git clone --branch "${repo_default_branch}" -- "${github_repo_ssh_url}" "${local_repo_path}"
  else
    info "local repo exists, fetching latest changes"
    run_cmd_always "git fetch" git -C "${local_repo_path}" fetch --prune --tags
  fi

  # verify it looks like a repo
  git -C "${local_repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "local_repo_path is not a valid git repo: ${local_repo_path}"

  info "repo sync complete: ${local_repo_path}"
}

main() {
  local github_repo_ssh_url="${1:-}"
  local local_repo_path="${2:-}"
  local repo_default_branch="${3:-}"

  [ -n "${github_repo_ssh_url}" ] || die "usage: sync_repo.sh <github_repo_ssh_url> <local_repo_path> <repo_default_branch>"
  [ -n "${local_repo_path}" ] || die "usage: sync_repo.sh <github_repo_ssh_url> <local_repo_path> <repo_default_branch>"
  [ -n "${repo_default_branch}" ] || die "usage: sync_repo.sh <github_repo_ssh_url> <local_repo_path> <repo_default_branch>"

  sync_repo "${github_repo_ssh_url}" "${local_repo_path}" "${repo_default_branch}"
}

main "$@"

