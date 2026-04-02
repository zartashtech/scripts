#!/usr/bin/env bash
# deploy/scripts/site_provision.sh
#
# provisions websites on the server based on site_inventory.ini:
# - creates site tree: /home/<website_id> and docroot /home/<website_id>/<docroot_subdir>
# - creates apache vhost pointing to php-fpm socket
# - optional: runs certbot for ssl
#
# notes:
# - expects apache + php8.4-fpm already installed (run server_bootstrap.sh first)
# - database provisioning/import is handled by deploy/scripts/db_provision.sh

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/helpers.sh"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run as root (use sudo)"
  fi
}

write_vhost() {
  local website_id="$1"
  local domain="$2"
  local docroot="$3"

  local vhost_path="/etc/apache2/sites-available/${website_id}.conf"

  cat > "${vhost_path}" <<EOF
<VirtualHost *:80>
  ServerName ${domain}

  DocumentRoot ${docroot}

  <Directory ${docroot}>
    AllowOverride All
    Require all granted
  </Directory>

  # php-fpm 8.4 via unix socket
  <FilesMatch \.php$>
    SetHandler "proxy:unix:/var/run/php/php8.4-fpm.sock|fcgi://localhost/"
  </FilesMatch>

  ErrorLog \${APACHE_LOG_DIR}/${website_id}-error.log
  CustomLog \${APACHE_LOG_DIR}/${website_id}-access.log combined
</VirtualHost>
EOF
}

run_certbot_if_enabled() {
  local website_id="$1"
  local domain="$2"
  local ssl="$3"
  local certbot_email="$4"

  if [ "${ssl}" != "yes" ]; then
    info "ssl: skip certbot for website_id=${website_id}"
    return 0
  fi

  [ -n "${certbot_email}" ] || die "ssl=yes but certbot_email is empty for website_id=${website_id}"

  require_cmd certbot
  require_cmd python3

  run_cmd_always "enable site" a2ensite "${website_id}.conf"
  systemctl reload apache2

  # this requires domain to be publicly reachable for http-01
  run_cmd "certbot apache" certbot --apache -n --agree-tos --redirect --email "${certbot_email}" -d "${domain}"
}

main() {
  require_root

  load_settings
  check_dependencies

  require_cmd apache2ctl
  require_cmd a2ensite
  require_cmd systemctl
  # mysql + ssh are used by db_provision.sh (separate step)

  local inv_path="${repo_root}/${inventory_file}"
  ensure_dir "${repo_root}/${logs_dir}"
  ensure_dir "${repo_root}/${tmp_dir}"

  local ts
  ts="$(date +"%Y%m%d-%H%M%S")"
  run_log_file="${repo_root}/${logs_dir}/provision-${ts}.log"

  info "start provisioning run_id=${ts}"
  run_cmd_always "validate inventory" bash "${script_dir}/validate_inventory.sh" "${inv_path}"

  bash "${script_dir}/cleanup_inactive_sites.sh" "${inv_path}"

  while IFS=$'\t' read -r website_id domain repo_folder site_home docroot_subdir branch active ssl certbot_email; do
    [ -n "${website_id}" ] || continue

    if [ "${active}" != "yes" ]; then
      info "skip inactive website_id=${website_id}"
      continue
    fi

    local site_root="${site_home}"
    local docroot="${site_home}/${docroot_subdir}"

    safe_abs_path_or_die "${site_root}"
    safe_abs_path_or_die "${docroot}"

    run_cmd "create site root" mkdir -p -- "${site_root}"
    run_cmd "create docroot" mkdir -p -- "${docroot}"

    write_vhost "${website_id}" "${domain}" "${docroot}"
    run_cmd_always "enable site" a2ensite "${website_id}.conf"

    systemctl reload apache2

    run_certbot_if_enabled "${website_id}" "${domain}" "${ssl}" "${certbot_email}"

    info "provision success website_id=${website_id} domain=${domain}"
  done < <(bash "${script_dir}/read_inventory.sh" "${inv_path}")

  info "provisioning finished log_file=${run_log_file}"
}

main "$@"

