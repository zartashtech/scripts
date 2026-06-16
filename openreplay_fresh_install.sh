#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenReplay Fresh Install (Ubuntu 24 + K3s)
#
# Usage:
# chmod +x openreplay_fresh_install.sh
# ./openreplay_fresh_install.sh replay.ticketlords.co.uk seyalamjad@gmail.com 178.18.249.71
#
# VERIFIED:
# Ubuntu 24.04
# K3s
# OpenReplay v1.27.x
# Single Node
# ============================================================

DOMAIN="${1:-}"
EMAIL="${2:-}"
PUBLIC_IP="${3:-}"

if [ -z "$DOMAIN" ]; then
    echo "Usage:"
    echo "./openreplay_fresh_install.sh domain email public_ip"
    exit 1
fi

echo "=================================================="
echo "Domain    : $DOMAIN"
echo "Email     : $EMAIL"
echo "Public IP : $PUBLIC_IP"
echo "=================================================="

echo "[1/8] Updating server"
apt update
apt upgrade -y

echo "[2/8] Installing required packages"
apt install -y \
curl \
wget \
git \
ufw \
dnsutils \
openssl \
ca-certificates

echo "[3/8] Configuring firewall"

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "[4/8] Installing K3s (Traefik disabled)"

curl -sfL https://get.k3s.io | \
K3S_KUBECONFIG_MODE="644" \
INSTALL_K3S_EXEC="--disable=traefik" \
sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "[5/8] Waiting for Kubernetes"

sleep 20

kubectl get nodes
kubectl get pods -A

echo "[6/8] Installing OpenReplay CLI"

wget -q \
https://raw.githubusercontent.com/openreplay/openreplay/main/scripts/helmcharts/openreplay-cli \
-O /usr/local/bin/openreplay

chmod +x /usr/local/bin/openreplay

echo "[7/8] Cleaning old OpenReplay installation"

rm -rf /var/lib/openreplay

echo "[8/8] Installing OpenReplay"

openreplay -i "$DOMAIN"

echo
echo "=================================================="
echo "OpenReplay Installation Finished"
echo "=================================================="

echo
echo "Checking Pods..."
kubectl get pods -A

echo
echo "Checking Services..."
kubectl get svc -A

echo
echo "Checking Ingress..."
kubectl get ingress -A

echo
echo "Checking Ingress Controller..."

kubectl get svc -n app openreplay-ingress-nginx-controller || true

echo
echo "Checking DNS..."

DNS_IP=$(dig +short "$DOMAIN" | tail -1 || true)

echo "DNS IP    : $DNS_IP"
echo "Server IP : $PUBLIC_IP"

echo
echo "=================================================="
echo "NEXT STEP: SSL"
echo "=================================================="

echo
echo "Run:"
echo
echo "cd /var/lib/openreplay/openreplay/scripts/helmcharts"
echo "bash certmanager.sh"
echo
echo "Enter:"
echo "Domain: $DOMAIN"
echo "Email : $EMAIL"
echo
echo "Then verify:"
echo
echo "kubectl get certificate -n app"
echo
echo "Expected:"
echo "openreplay-ssl   True"
echo
echo "Finally:"
echo
echo "curl -Ik https://$DOMAIN"
echo
echo "=================================================="
