#!/bin/bash

set -e

# ==============================
# USER VARIABLES
# ==============================
domain="protendersolutions.co.uk"
ssl_email="seyalamjad@gmail.com"
directory_username="protender"
files_transfer_from="https://www.protendersolutions.co.uk/web_transfer.zip"

# ==============================
# AUTO VARIABLES
# ==============================
web_root="/home/${directory_username}/public_html"
apache_conf="/etc/apache2/sites-available/${domain}.conf"
zip_file="/tmp/${domain}_web_transfer.zip"

echo "=========================================="
echo "Starting LAMP domain setup"
echo "Domain: $domain"
echo "SSL Email: $ssl_email"
echo "Directory User: $directory_username"
echo "Web Root: $web_root"
echo "Transfer File: $files_transfer_from"
echo "=========================================="

apt update
apt install -y apache2 software-properties-common unzip curl certbot python3-certbot-apache
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.4 libapache2-mod-php8.4 php8.4-cli php8.4-mbstring

mkdir -p "/home/${directory_username}"
mkdir -p "$web_root"

chown -R www-data:www-data "$web_root"
chmod 755 /home
chmod 755 "/home/${directory_username}"
chmod 755 "$web_root"

curl -fL "$files_transfer_from" -o "$zip_file"
unzip -o "$zip_file" -d "$web_root"
rm -f "$zip_file"

chown -R www-data:www-data "$web_root"

cat > "$apache_conf" <<EOF
<VirtualHost *:80>
    ServerName ${domain}
    ServerAlias www.${domain}

    DocumentRoot ${web_root}

    <Directory ${web_root}>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined
</VirtualHost>
EOF

a2enmod rewrite
a2ensite "${domain}.conf"
a2dissite 000-default.conf || true
systemctl restart apache2

certbot --apache \
-d "${domain}" \
-d "www.${domain}" \
-m "${ssl_email}" \
--agree-tos \
--no-eff-email \
--redirect \
-n

systemctl reload apache2

echo "Setup completed successfully"
echo "Domain: $domain"
echo "Web Root: $web_root"
