#!/bin/bash

set -e

echo "Updating system..."
apt update

echo "Installing Apache..."
apt install -y apache2 software-properties-common

echo "Adding PHP repository..."
add-apt-repository ppa:ondrej/php -y
apt update

echo "Installing PHP 8.4..."
apt install -y php8.4 libapache2-mod-php8.4 php8.4-cli php8.4-mbstring

echo "Creating website directory..."
mkdir -p /home/protender/public_html
chown -R www-data:www-data /home/protender/public_html
chmod 755 /home /home/protender /home/protender/public_html

echo "Creating Apache VirtualHost..."

cat <<'EOF' > /etc/apache2/sites-available/protendersolutions.co.uk.conf
<VirtualHost *:80>
    ServerName protendersolutions.co.uk
    ServerAlias www.protendersolutions.co.uk

    DocumentRoot /home/protender/public_html

    <Directory /home/protender/public_html>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/protendersolutions_error.log
    CustomLog ${APACHE_LOG_DIR}/protendersolutions_access.log combined
</VirtualHost>
EOF

echo "Enabling Apache site..."
a2enmod rewrite
a2ensite protendersolutions.co.uk.conf
systemctl restart apache2

echo "Installing Certbot..."
apt update
apt install -y certbot python3-certbot-apache

echo "Requesting SSL..."
certbot --apache -d protendersolutions.co.uk -d www.protendersolutions.co.uk

systemctl reload apache2

echo "----------------------------------"
echo "Setup completed successfully"
echo "Website root: /home/protender/public_html"
echo "----------------------------------"
