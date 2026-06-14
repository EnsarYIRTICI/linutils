#!/bin/bash
# systemd-networkd-wait-online mask scripti
# Kullanım: ./mask_network_wait.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "HATA: Root olarak çalıştırın." >&2
    exit 1
fi

SERVICE="systemd-networkd-wait-online.service"

echo "[*] $SERVICE maskeleniyor..."

systemctl disable "$SERVICE" 2>/dev/null || true
systemctl mask "$SERVICE"
systemctl daemon-reload

STATUS=$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)
echo "[+] Servis durumu: $STATUS"
echo "[+] Tamamlandı. Bir sonraki boot'tan itibaren bekleme olmayacak."