#!/bin/bash
set -euo pipefail
trap 'echo "❌ Hata oluştu. Komut: $BASH_COMMAND"; exit 1' ERR

ZONES_CONFIG_DIR="/etc/bind/zones-config"

# 📁 Zone config dizini yoksa oluştur
if [ ! -d "$ZONES_CONFIG_DIR" ]; then
    echo "⚠️ Zone config dizini bulunamadı, oluşturuluyor: $ZONES_CONFIG_DIR"
    sudo mkdir -p "$ZONES_CONFIG_DIR"
    echo "✅ Zone config dizini oluşturuldu."
fi

echo "🌐 Tanımlı zone dosyaları:"
echo "---------------------------"

# ✅ Boş glob durumunda hata vermesin
shopt -s nullglob

# ✅ Zone config dosyalarını oku
for config_file in "$ZONES_CONFIG_DIR"/*.zones; do
    echo "📂 $(basename "$config_file")"
    grep 'zone "' "$config_file" | awk -F'"' '{print "  - " $2}'
done

# ✅ Eğer hiç dosya bulunamadıysa mesaj ver
if ! ls "$ZONES_CONFIG_DIR"/*.zones >/dev/null 2>&1; then
    echo "ℹ️  Henüz herhangi bir zone dosyası yok."
fi
