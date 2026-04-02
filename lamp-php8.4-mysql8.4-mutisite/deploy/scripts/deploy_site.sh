#!/usr/bin/env bash
# deploy/scripts/deploy_site.sh
#
# deploys ONE site:
# - verifies repo folder exists in the given branch (without switching branches)
# - stages files using `git archive` into a temp directory
# - rsyncs staged files to the site docroot (arg 6: full path e.g. /home/site1/public_html)

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "${script_dir}/helpers.sh"

deploy_one_site() {
  local local_repo_path="$1"
  local tmp_dir="$2"
  local website_id="$3"
  local domain="$4"
  local repo_folder="$5"
  local docroot_path="$6"
  local branch="$7"
  local enable_delete="$8"
  local create_live_dirs="$9"
  local rsync_base_opts="${10}"
  local exclude_file="${11}"

  safe_abs_path_or_die "${local_repo_path}"
  safe_abs_path_or_die "${tmp_dir}"
  safe_abs_path_or_die "${docroot_path}"
  [ -n "${website_id}" ] || die "internal error: empty website_id"
  [ -n "${repo_folder}" ] || die "internal error: empty repo_folder"
  [ -n "${branch}" ] || die "internal error: empty branch"
  is_yes_no "${enable_delete}" || die "invalid enable_delete value: ${enable_delete}"
  is_yes_no "${create_live_dirs}" || die "invalid create_live_dirs value: ${create_live_dirs}"

  info "deploying website_id=${website_id} domain=${domain} repo_folder=${repo_folder} branch=${branch} docroot_path=${docroot_path}"

  if [ ! -d "${local_repo_path}/.git" ]; then
    die "local repo missing or invalid: ${local_repo_path}"
  fi

  # confirm repo_folder exists on the requested branch (do not rely on working tree)
  if ! git -C "${local_repo_path}" cat-file -e "${branch}:${repo_folder}" 2>/dev/null; then
    die "repo folder not found in repo: branch=${branch} folder=${repo_folder}"
  fi

  if [ ! -d "${docroot_path}" ]; then
    if [ "${create_live_dirs}" = "yes" ]; then
      run_cmd "create docroot directory" mkdir -p -- "${docroot_path}"
    else
      die "docroot does not exist and create_live_dirs=no: ${docroot_path}"
    fi
  fi

  # stage the site content into a temp folder.
  # this avoids changing git branches and supports multiple site branches in one run.
  local stage_root
  stage_root="$(mktemp -d --tmpdir="${tmp_dir}" "deploy-${website_id}-XXXXXX")"

  # cleanup staging dir on exit from this function
  # shellcheck disable=SC2064
  trap 'rm -rf -- "${stage_root}" 2>/dev/null || true' RETURN

  local tar_path="${stage_root}/site.tar"
  local extract_root="${stage_root}/extract"
  mkdir -p -- "${extract_root}"

  # git archive outputs the folder as a top-level directory in the tar
  run_cmd_always "git archive" git -C "${local_repo_path}" archive --format=tar --output="${tar_path}" "${branch}" "${repo_folder}"

  # extracting is safe in dry-run because it happens in tmp dir, not live
  run_cmd_always "extract archive" tar -xf "${tar_path}" -C "${extract_root}"

  local src="${extract_root}/${repo_folder}"
  if [ ! -d "${src}" ]; then
    die "staged source directory not found after archive: ${src}"
  fi

  safe_sync_paths_or_die "${src}" "${docroot_path}"

  # build rsync args
  local -a rsync_args
  # shellcheck disable=SC2206
  rsync_args=(${rsync_base_opts})

  # dry run flag (rsync supports -n)
  if [ "${dry_run}" = "yes" ]; then
    rsync_args+=("-n")
  fi

  # always exclude .git (even if present in staged content)
  rsync_args+=("--exclude=.git")

  if [ -n "${exclude_file}" ]; then
    rsync_args+=("--exclude-from=${exclude_file}")
  fi

  if [ "${enable_delete}" = "yes" ]; then
    rsync_args+=("--delete")
  fi

  # ensure trailing slashes to copy folder contents, not the folder itself
  info "rsync source=${src}/ dest=${docroot_path}/"
  rsync "${rsync_args[@]}" -- "${src}/" "${docroot_path}/" >> "${run_log_file}" 2>&1 \
    || die "rsync failed for website_id=${website_id}"

  info "deploy success website_id=${website_id} domain=${domain}"
}

main() {
  # this script is usually called from deploy.sh
  # args are positional on purpose (simple + avoids parsing here)
  if [ "$#" -ne 11 ]; then
    die "usage: deploy_site.sh <local_repo_path> <tmp_dir> <website_id> <domain> <repo_folder> <docroot_path> <branch> <enable_delete> <create_live_dirs> <rsync_base_opts> <exclude_file>"
  fi

  deploy_one_site "$@"
}

main "$@"

