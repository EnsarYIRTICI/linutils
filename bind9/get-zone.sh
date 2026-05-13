#!/bin/bash
set -euo pipefail
trap 'echo "❌ Hata oluştu. Komut: $BASH_COMMAND"; exit 1' ERR

# 🟢 Kullanıcıdan domain al
if [ -n "${1:-}" ]; then
    DOMAIN="$1"
else
    read -p "Bilgisi görüntülenecek domain adını girin: " DOMAIN
fi

# Domain format kontrolü
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]+$ ]]; then
    echo "Geçersiz domain formatı. Örnek: example.com"
    exit 1
fi

TLD=$(echo "$DOMAIN" | awk -F. '{print $(NF)}')
ZONE_FILE="/etc/bind/zones/$TLD/db.${DOMAIN}"

# Zone dosyası kontrolü
if [ ! -f "$ZONE_FILE" ]; then
    echo "❌ Zone dosyası bulunamadı: $ZONE_FILE"
    exit 1
fi

echo "📄 Zone bilgileri: $DOMAIN"
echo "--------------------------------"
cat "$ZONE_FILE"
