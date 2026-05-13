#!/bin/bash
set -euo pipefail
trap 'echo "❌ Bir hata oluştu. Komut: $BASH_COMMAND"; exit 1' ERR

# 📥 Kullanım: ./update_bind_zone_by_tld.sh [tld] [key-name]
TLD="${1:-}"
if [[ -z "$TLD" ]]; then
    read -rp "Lütfen güncellenecek TLD'yi girin (örn: msi): " TLD
fi

KEY_NAME="${2:-}"
if [[ -z "$KEY_NAME" ]]; then
    read -rp "Lütfen kullanılacak key adını girin (örn: ddns-msi): " KEY_NAME
fi

CONF_FILE="/etc/bind/zones-config/${TLD}.zones"

# 🔍 Dosya var mı?
if [[ ! -f "$CONF_FILE" ]]; then
    echo "❌ HATA: Zone config dosyası bulunamadı: $CONF_FILE"
    exit 1
fi

echo "🔍 $TLD için zone'lar taranıyor..."

# 🧾 Zone isimlerini çek
ZONES=($(grep 'zone "' "$CONF_FILE" | awk -F'"' '{print $2}'))

if [[ ${#ZONES[@]} -eq 0 ]]; then
    echo "❌ HATA: '$TLD' için tanımlı hiçbir zone bulunamadı."
    exit 1
fi

for DOMAIN in "${ZONES[@]}"; do
    echo "🛠️ $DOMAIN için 'allow-update' kontrol ediliyor..."

    if grep -A 5 "zone \"$DOMAIN\" {" "$CONF_FILE" | grep -q "allow-update"; then
        echo "🔄 'allow-update' bulundu. Güncelleniyor..."
        sudo sed -i "/zone \"$DOMAIN\" {/,/};/s/allow-update {[^}]*}/allow-update { key \"$KEY_NAME\"; }/" "$CONF_FILE"
        echo "✅ $DOMAIN güncellendi."
    else
        echo "➕ 'allow-update' eksik. Ekleniyor..."
        sudo sed -i "/zone \"$DOMAIN\" {/,/};/s|};| allow-update { key \"$KEY_NAME\"; };\n};|" "$CONF_FILE"
        echo "✅ $DOMAIN zone'una 'allow-update' eklendi."
    fi
done

# 🔄 BIND reload
echo "🔄 BIND yeniden yükleniyor..."
sudo rndc reload

echo "✅ Tamamlandı: '$TLD' TLD'sine ait tüm zone'lar '$KEY_NAME' ile güncellendi."
