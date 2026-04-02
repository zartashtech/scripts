#!/usr/bin/env bash
# deploy/scripts/server_bootstrap.sh
#
# one-time server bootstrap for ubuntu 24:
# - apache
# - php 8.4 + php-fpm
# - mysql 8.4 (from mysql official apt repo)
# - basic tools used by this deployment system
#
# safety:
# - runs as root
# - stops on errors

set -euo pipefail

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "error: run as root (use sudo)" >&2
    exit 1
  fi
}

apt_install() {
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

ensure_php84() {
  # ondrej/php provides php8.4 packages on ubuntu 24
  if ! apt-cache show php8.4-fpm >/dev/null 2>&1; then
    apt_install software-properties-common ca-certificates lsb-release apt-transport-https
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y
  fi

  apt_install apache2 libapache2-mod-fcgid \
    php8.4 php8.4-fpm php8.4-cli \
    php8.4-mysql php8.4-curl php8.4-mbstring php8.4-xml php8.4-zip

  a2enmod proxy_fcgi setenvif rewrite headers ssl http2 || true
  a2enconf php8.4-fpm || true
  systemctl enable --now php8.4-fpm
  systemctl enable --now apache2
  systemctl reload apache2
}

ensure_mysql84() {
  # installs mysql 8.4 lts from mysql official apt repo
  # note: this may prompt for options on first install (mysql-apt-config)
  if ! apt-cache policy mysql-server 2>/dev/null | grep -q "repo.mysql.com"; then
    apt_install wget gnupg
    tmp_deb="$(mktemp)"
    wget -O "${tmp_deb}" "https://dev.mysql.com/get/mysql-apt-config_0.8.34-1_all.deb"
    dpkg -i "${tmp_deb}" || true
    rm -f -- "${tmp_deb}"
    apt-get update -y
  fi

  apt_install mysql-server
  systemctl enable --now mysql
}

main() {
  require_root
  export DEBIAN_FRONTEND=noninteractive

  apt_install git rsync awk sed grep tar curl openssh-client

  ensure_php84
  ensure_mysql84

  echo "bootstrap complete"
  echo "next: run deploy/scripts/site_provision.sh"
}

main "$@"

