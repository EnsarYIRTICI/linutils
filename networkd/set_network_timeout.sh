#!/bin/bash
# systemd-networkd-wait-online timeout ayarlayıcı
# Kullanım: ./set_network_timeout.sh [saniye]
# Örnek:    ./set_network_timeout.sh 3

set -euo pipefail

TIMEOUT=${1:-3}
OVERRIDE_DIR="/etc/systemd/system/systemd-networkd-wait-online.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"

# Sayısal kontrol
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "HATA: Geçerli bir sayı girin. Örnek: $0 3" >&2
    exit 1
fi

# Root kontrolü
if [[ $EUID -ne 0 ]]; then
    echo "HATA: Bu script root olarak çalıştırılmalı." >&2
    exit 1
fi

echo "[*] Timeout ${TIMEOUT}s olarak ayarlanıyor..."

mkdir -p "$OVERRIDE_DIR"

cat > "$OVERRIDE_FILE" << EOF
[Service]
TimeoutStartSec=${TIMEOUT}
EOF

systemctl daemon-reload

CURRENT=$(systemctl show systemd-networkd-wait-online.service | grep TimeoutStartUSec)
echo "[+] Uygulanan ayar: $CURRENT"
echo "[+] Tamamlandı. Değişiklik bir sonraki boot'ta aktif olacak."