#!/usr/bin/env bash
# deploy/scripts/validate_db_inventory.sh
#
# validates db_inventory.ini:
# - local db names unique
# - source names unique
# - mapping refers to existing local_db and source
# - enabled values yes/no
# - db_create values yes/no

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/helpers.sh"

validate_db_inventory_file() {
  local inv="$1"
  [ -f "${inv}" ] || die "db inventory file not found: ${inv}"

  local parsed
  parsed="$(bash "${script_dir}/read_db_inventory.sh" "${inv}")" || die "db inventory parse failed: ${inv}"

  awk -F'\t' '
    function die(msg) { print msg > "/dev/stderr"; exit 2 }
    function is_yes_no(v) { return (v=="yes" || v=="no") }
    $1=="local" {
      name=$2; db_name=$3; db_host=$4; users_csv=$5; db_create=$6
      if (seen_local[name]++) die("duplicate local_db section: " name)
      if (db_name=="") die("local_db missing db_name: " name)
      if (users_csv=="") die("local_db missing db_user/db_users: " name)
      if (!is_yes_no(db_create)) die("local_db invalid db_create (yes/no): " name)
      # duplicate mysql user names in same section
      delete count
      n=split(users_csv, ua, ",")
      for (i=1;i<=n;i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", ua[i])
        if (ua[i]=="") continue
        if (count[ua[i]]++) die("duplicate mysql user in [local_db:" name "]: " ua[i])
      }
      local_name_by_db[db_name]=name
      next
    }
    $1=="source" {
      name=$2; ssh_host=$3; ssh_user=$4; ssh_port=$5; defaults=$6; sudo_dump=$7
      if (seen_source[name]++) die("duplicate source section: " name)
      if (ssh_host=="" || ssh_user=="") die("source missing ssh_host/ssh_user: " name)
      if (ssh_port=="" ) die("source missing ssh_port: " name)
      if (sudo_dump!="" && !is_yes_no(sudo_dump)) die("source invalid sudo_mysqldump (yes/no): " name)
      next
    }
    $1=="map" {
      name=$2; enabled=$3; local_db=$4; source=$5; source_db=$6
      if (seen_map[name]++) die("duplicate map section: " name)
      if (!is_yes_no(enabled)) die("map invalid enabled (yes/no): " name)
      maps_count++
      map_local[name]=local_db
      map_source[name]=source
      next
    }
    END {
      # validate map refs
      for (m in map_local) {
        if (!(map_local[m] in seen_local)) die("map references missing local_db: map=" m " local_db=" map_local[m])
        if (!(map_source[m] in seen_source)) die("map references missing source: map=" m " source=" map_source[m])
      }
    }
  ' <<< "${parsed}" || die "db inventory validation failed: ${inv}"

  info "db inventory validation ok: ${inv}"
}

main() {
  local inv="${1:-}"
  [ -n "${inv}" ] || die "usage: validate_db_inventory.sh /path/to/db_inventory.ini"
  validate_db_inventory_file "${inv}"
}

main "$@"

