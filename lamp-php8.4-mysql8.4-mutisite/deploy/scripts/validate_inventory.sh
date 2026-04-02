#!/usr/bin/env bash
# deploy/scripts/validate_inventory.sh
#
# validates the inventory INI file.
# this script is strict on purpose to keep deployments safe.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "${script_dir}/helpers.sh"

validate_inventory_file() {
  local inv="$1"

  [ -f "${inv}" ] || die "inventory file not found: ${inv}"

  # parse inventory and validate uniqueness + values
  # we reuse read_inventory.sh so deploy and validate always agree.
  local lines
  lines="$(bash "${script_dir}/read_inventory.sh" "${inv}")" || die "inventory parse failed: ${inv}"

  # now validate the parsed lines
  awk -F'\t' '
    function die(msg) { print msg > "/dev/stderr"; exit 2 }
    function is_yes_no(v) { return (v=="yes" || v=="no") }
    {
      website_id=$1
      domain=$2
      repo_folder=$3
      site_home=$4
      docroot_subdir=$5
      branch=$6
      active=$7
      ssl=$8
      certbot_email=$9

      if (website_id=="" || domain=="" || repo_folder=="" || site_home=="" || branch=="" || active=="") die("missing required field after parsing (check site_inventory.ini)")

      if (!is_yes_no(active)) die("invalid active (must be yes/no) for website_id=" website_id)
      if (!is_yes_no(ssl)) die("invalid ssl (must be yes/no) for website_id=" website_id)

      if (substr(site_home,1,1) != "/") die("site_home must be absolute for website_id=" website_id)
      if (site_home=="/") die("site_home cannot be / for website_id=" website_id)
      expected="/home/" website_id
      if (site_home != expected) die("site_home must be /home/" website_id " (got " site_home ")")

      # convention: repo folder must start with website_id
      if (index(repo_folder, website_id) != 1) die("repo_folder must start with website_id: website_id=" website_id " repo_folder=" repo_folder)

      if (seen_id[website_id]++) die("duplicate website_id: " website_id)
      if (seen_domain[domain]++) die("duplicate domain: " domain)
      if (seen_home[site_home]++) die("duplicate site_home: " site_home)
    }
    END { exit 0 }
  ' <<< "${lines}" || die "inventory validation failed: ${inv}"

  info "inventory validation ok: ${inv}"
}

main() {
  local inv="${1:-}"
  [ -n "${inv}" ] || die "usage: validate_inventory.sh /path/to/site_inventory.ini"
  validate_inventory_file "${inv}"
}

main "$@"

