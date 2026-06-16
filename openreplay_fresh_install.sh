#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenReplay Fresh Install on Ubuntu 24 + K3s
# Verified flow:
# - Install K3s without Traefik
# - Install OpenReplay using official openreplay-cli
# - Confirm LoadBalancer external IP
# - Install SSL using certmanager.sh
#
# Usage:
#   chmod +x openreplay_fresh_install.sh
#   sudo ./openreplay_fresh_install.sh replay.ticketlords.co.uk seyalamjad@gmail.com 178.18.249.71
# ============================================================

DOMAIN="${1:-replay.ticketlords.co.uk}"
EMAIL="${2:-seyalamjad@gmail.com}"
PUBLIC_IP="${3:-178.18.249.71}"

echo "[INFO] Domain: $DOMAIN"
echo "[INFO] Email: $EMAIL"
echo "[INFO] Public IP: $PUBLIC_IP"

echo "[1/10] System update and packages"
apt update && apt upgrade -y
apt install -y curl wget git ufw dnsutils openssl ca-certificates

echo "[2/10] Firewall"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status

echo "[3/10] Install K3s without Traefik"
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" INSTALL_K3S_EXEC="--disable=traefik" sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "[4/10] Confirm Kubernetes"
kubectl get nodes
kubectl get pods -A

echo "[5/10] Install OpenReplay CLI"
wget https://raw.githubusercontent.com/openreplay/openreplay/main/scripts/helmcharts/openreplay-cli -O /bin/openreplay
chmod +x /bin/openreplay

echo "[6/10] Clean any old OpenReplay directory/state"
rm -rf /var/lib/openreplay

echo "[7/10] Install OpenReplay"
openreplay -i "$DOMAIN"

echo "[8/10] Verify OpenReplay pods/services/ingress"
kubectl get pods -A
kubectl get svc -A | grep -E "openreplay|ingress|nginx" || true
kubectl get ingress -A || true

echo "[9/10] Ensure LoadBalancer has public IP"
if ! kubectl get svc -n app openreplay-ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q .; then
  echo "[WARN] LoadBalancer IP not found. Patching externalIPs with $PUBLIC_IP"
  kubectl patch svc -n app openreplay-ingress-nginx-controller \
    -p "{\"spec\":{\"externalIPs\":[\"$PUBLIC_IP\"]}}"
  kubectl rollout restart deployment -n app openreplay-ingress-nginx-controller
  kubectl rollout status deployment -n app openreplay-ingress-nginx-controller
fi

echo "[10/10] DNS check"
echo "DNS result:"
dig +short "$DOMAIN" || true
echo "Server public IP:"
curl -4 ifconfig.me || true
echo

echo "[INFO] Test HTTP before SSL"
curl -I "http://$DOMAIN" || true

echo
echo "============================================================"
echo "NEXT: SSL installation is interactive."
echo "Run this command and enter:"
echo "Domain: $DOMAIN"
echo "Email:  $EMAIL"
echo "============================================================"
echo
echo "cd /var/lib/openreplay/openreplay/scripts/helmcharts && bash certmanager.sh"
echo
echo "After SSL script finishes, run:"
echo "sleep 90"
echo "kubectl get certificate,order,challenge -n app"
echo "curl -Ik https://$DOMAIN"
echo
echo "Expected certificate:"
echo "openreplay-ssl   True"
echo "============================================================"
