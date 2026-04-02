#!/usr/bin/env bash
# deploy/scripts/read_db_inventory.sh
#
# reads db_inventory.ini and prints:
# - local dbs
# - sources
# - mappings
#
# output lines are prefixed by type and tab-separated.
#
# local:
#   local   local_name  db_name  db_host  db_users_csv  db_create
#   db_users_csv: comma-separated mysql users (no spaces around commas) OR a single user from db_user=
#
# source:
#   source  source_name ssh_host ssh_user ssh_port mysql_defaults_file sudo_mysqldump
#
# map:
#   map     map_name    enabled  local_db source  source_db

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/helpers.sh"

read_db_inventory_ini() {
  local inv="$1"
  [ -f "${inv}" ] || die "db inventory file not found: ${inv}"

  awk '
    function trim(s) { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
    function flush() {
      if (sect=="") return

      if (kind=="local_db") {
        if (kv["db_name"]=="" || kv["db_host"]=="" || kv["db_create"]=="") {
          printf("missing required keys in [local_db:%s] (need db_name, db_host, db_create)\n", name) > "/dev/stderr"; exit 2
        }
        users = ""
        if (kv["db_users"] != "") {
          users = kv["db_users"]
        } else if (kv["db_user"] != "") {
          users = kv["db_user"]
        } else {
          printf("missing db_user or db_users in [local_db:%s]\n", name) > "/dev/stderr"; exit 2
        }
        printf("local\t%s\t%s\t%s\t%s\t%s\n", name, kv["db_name"], kv["db_host"], users, kv["db_create"])
      } else if (kind=="source") {
        if (kv["ssh_host"]=="" || kv["ssh_user"]=="" ) {
          printf("missing required keys in [source:%s]\n", name) > "/dev/stderr"; exit 2
        }
        if (kv["ssh_port"]=="") kv["ssh_port"]="22"
        if (kv["mysql_defaults_file"]=="") kv["mysql_defaults_file"]="/root/.my.cnf"
        if (kv["sudo_mysqldump"]=="") kv["sudo_mysqldump"]="yes"
        printf("source\t%s\t%s\t%s\t%s\t%s\t%s\n", name, kv["ssh_host"], kv["ssh_user"], kv["ssh_port"], kv["mysql_defaults_file"], kv["sudo_mysqldump"])
      } else if (kind=="map") {
        if (kv["enabled"]=="") kv["enabled"]="yes"
        if (kv["local_db"]=="" || kv["source"]=="" || kv["source_db"]=="") {
          printf("missing required keys in [map:%s]\n", name) > "/dev/stderr"; exit 2
        }
        printf("map\t%s\t%s\t%s\t%s\t%s\n", name, kv["enabled"], kv["local_db"], kv["source"], kv["source_db"])
      } else {
        printf("unknown section type: %s\n", sect) > "/dev/stderr"; exit 2
      }
    }

    BEGIN { sect=""; kind=""; name=""; }
    {
      line=$0
      gsub(/\r$/, "", line)
      if (line ~ /^[ \t]*$/) next
      if (line ~ /^[ \t]*#/) next
      if (line ~ /^[ \t]*;/) next

      if (line ~ /^[ \t]*\[[^]]+\][ \t]*$/) {
        flush()
        sect=line
        gsub(/^[ \t]*\[/, "", sect)
        gsub(/\][ \t]*$/, "", sect)

        split(sect, a, ":")
        if (length(a) != 2) { printf("invalid section header: [%s]\n", sect) > "/dev/stderr"; exit 2 }
        kind=trim(a[1])
        name=trim(a[2])
        delete kv
        next
      }

      split(line, parts, "=")
      if (length(parts) < 2) { printf("invalid line (expected key=value): %s\n", line) > "/dev/stderr"; exit 2 }
      key=trim(parts[1])
      val=substr(line, index(line,"=")+1)
      val=trim(val)
      if (sect=="") { printf("key/value outside a section: %s\n", line) > "/dev/stderr"; exit 2 }
      kv[key]=val
    }
    END { flush() }
  ' "${inv}"
}

main() {
  local inv="${1:-}"
  [ -n "${inv}" ] || die "usage: read_db_inventory.sh /path/to/db_inventory.ini"
  read_db_inventory_ini "${inv}"
}

main "$@"

