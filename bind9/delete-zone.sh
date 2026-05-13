#!/bin/bash
set -euo pipefail
trap 'echo "❌ Bir hata oluştu. Komut: $BASH_COMMAND"; exit 1' ERR

# 📥 Argüman: 1 = DOMAIN
DOMAIN="${1:-}"

# Kullanıcıdan domain al
if [[ -z "$DOMAIN" ]]; then
    read -rp "🔹 Silmek istediğiniz domain adını girin (örn: example.com): " DOMAIN
fi

# ✔️ Domain kontrolü
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]+$ ]]; then
    echo "❌ Geçersiz domain formatı: $DOMAIN"
    exit 1
fi

# 📂 TLD'ye göre yol belirle
TLD=$(echo "$DOMAIN" | awk -F. '{print $(NF)}')
ZONE_FILE="/etc/bind/zones/$TLD/db.${DOMAIN}"
ZONE_CONF_FILE="/etc/bind/zones-config/${TLD}.zones"

# 🧹 Zone tanımını zone config dosyasından sil
if [[ -f "$ZONE_CONF_FILE" ]]; then
    echo "🔍 Zone tanımı kaldırılıyor: $DOMAIN"
    sudo sed -i "/zone \"$DOMAIN\" {/,/};/d" "$ZONE_CONF_FILE"
else
    echo "⚠️ Zone config dosyası bulunamadı: $ZONE_CONF_FILE"
fi

# 🗑️ Zone dosyasını sil
if [[ -f "$ZONE_FILE" ]]; then
    echo "🗑️ Zone dosyası siliniyor: $ZONE_FILE"
    sudo rm -f "$ZONE_FILE"
else
    echo "⚠️ Zone dosyası zaten yok: $ZONE_FILE"
fi

# 🔄 Yapılandırma testi ve BIND reload
echo "🔍 BIND yapılandırması kontrol ediliyor..."
sudo named-checkconf

echo "🔁 BIND servisi yeniden yükleniyor..."
sudo rndc reload

echo "✅ Zone başarıyla silindi: $DOMAIN"
