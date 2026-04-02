#!/usr/bin/env bash
# deploy/scripts/read_inventory.sh
#
# reads site_inventory.ini and prints one site per line (tab-separated):
#   website_id  domain  repo_folder  site_home  docroot_subdir  branch  active  ssl  certbot_email
#
# rules:
# - section header [name] is the website_id (not a placeholder; it is the canonical id)
# - site_home is always /home/<website_id> (computed; never read from file — no live_directory= line)
# - do not set website_id= or live_directory= inside a section (parser rejects them)

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "${script_dir}/helpers.sh"

read_inventory_ini() {
  local inv="$1"
  [ -f "${inv}" ] || die "site inventory file not found: ${inv}"

  awk '
    function trim(s) {
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s)
      return s
    }
    function flush_site() {
      if (current=="") return

      wid = trim(current)
      if (wid == "") {
        printf("empty section name\n") > "/dev/stderr"
        exit 2
      }
      # website_id: lowercase start, then letters, digits, underscore, hyphen
      if (wid !~ /^[a-z][a-z0-9_-]*$/) {
        printf("invalid section name (website_id) [%s]: use lowercase start, then a-z 0-9 _ -\n", wid) > "/dev/stderr"
        exit 2
      }
      if (site["website_id"] != "" && site["website_id"] != wid) {
        printf("website_id=%s conflicts with section [%s]\n", site["website_id"], wid) > "/dev/stderr"
        exit 2
      }
      if (site["live_directory"] != "") {
        printf("live_directory must not be set in [%s] (always /home/%s)\n", wid, wid) > "/dev/stderr"
        exit 2
      }

      if (site["domain"]=="" || site["repo_folder"]=="" || site["branch"]=="" || site["active"]=="") {
        printf("missing required keys in section [%s]: need domain, repo_folder, branch, active\n", wid) > "/dev/stderr"
        exit 2
      }

      if (site["docroot_subdir"]=="") site["docroot_subdir"]="public_html"
      if (site["ssl"]=="") site["ssl"]="no"

      site_home = "/home/" wid

      printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        wid,
        site["domain"],
        site["repo_folder"],
        site_home,
        site["docroot_subdir"],
        site["branch"],
        site["active"],
        site["ssl"],
        site["certbot_email"]
      )
    }

    BEGIN {
      current=""
    }

    {
      line=$0
      gsub(/\r$/, "", line)
      if (line ~ /^[ \t]*$/) next
      if (line ~ /^[ \t]*#/) next
      if (line ~ /^[ \t]*;/) next

      # portable: no gawk-only match(..., ..., arr)
      if (line ~ /^[ \t]*\[[^]]+\][ \t]*$/) {
        flush_site()
        current=line
        gsub(/^[ \t]*\[/, "", current)
        gsub(/\][ \t]*$/, "", current)
        delete site
        next
      }

      split(line, parts, "=")
      if (length(parts) < 2) {
        printf("invalid line (expected key=value): %s\n", line) > "/dev/stderr"
        exit 2
      }
      key=trim(parts[1])
      val=substr(line, index(line,"=")+1)
      val=trim(val)

      if (current=="") {
        printf("key/value outside a section: %s\n", line) > "/dev/stderr"
        exit 2
      }
      if (key=="") {
        printf("empty key in section [%s]\n", current) > "/dev/stderr"
        exit 2
      }

      if (key == "website_id" || key == "live_directory") {
        printf("key \"%s\" is not allowed in [%s] (website_id is the section name; live_directory is /home/%s)\n", key, trim(current), trim(current)) > "/dev/stderr"
        exit 2
      }

      site[key]=val
    }

    END {
      flush_site()
    }
  ' "${inv}"
}

main() {
  local inv="${1:-}"
  [ -n "${inv}" ] || die "usage: read_inventory.sh /path/to/site_inventory.ini"
  read_inventory_ini "${inv}"
}

main "$@"
