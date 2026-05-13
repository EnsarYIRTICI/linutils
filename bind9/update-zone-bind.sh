#!/bin/bash
set -euo pipefail
trap 'echo "❌ Bir hata oluştu. Komut: $BASH_COMMAND"; exit 1' ERR

# 📥 Kullanım: ./update_bind_zone.sh [domain] [key-name]
DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
    read -rp "Lütfen domain adını girin (örnek: example.com): " DOMAIN
fi

KEY_NAME="${2:-}"
if [[ -z "$KEY_NAME" ]]; then
    read -rp "Lütfen kullanılacak key adını girin (örnek: ddns-msi): " KEY_NAME
fi

# 📁 TLD'yi ayıkla → config dosyasını bul
TLD=$(echo "$DOMAIN" | awk -F. '{print $(NF)}')
CONF_FILE="/etc/bind/zones-config/${TLD}.zones"

# 🕵️ Zone tanımı bu dosyada var mı?
if ! grep -q "zone \"$DOMAIN\" {" "$CONF_FILE"; then
    echo "❌ HATA: $DOMAIN zone'u $CONF_FILE içinde bulunamadı."
    exit 1
fi

# 🧠 allow-update var mı kontrol et
if grep -A 5 "zone \"$DOMAIN\" {" "$CONF_FILE" | grep -q "allow-update"; then
    echo "🔄 'allow-update' satırı bulundu. Güncelleniyor..."
    sudo sed -i "/zone \"$DOMAIN\" {/,/};/s/allow-update {[^}]*}/allow-update { key \"$KEY_NAME\"; }/" "$CONF_FILE"
    echo "✅ $DOMAIN zone'undaki 'allow-update' satırı '$KEY_NAME' ile güncellendi."
else
    echo "➕ 'allow-update' satırı yok. Ekleniyor..."
    sudo sed -i "/zone \"$DOMAIN\" {/,/};/s|};| allow-update { key \"$KEY_NAME\"; };\n};|" "$CONF_FILE"
    echo "✅ $DOMAIN zone'una 'allow-update' satırı başarıyla eklendi."
fi

# 🔄 BIND reload
echo "🔄 BIND yeniden yükleniyor..."
sudo rndc reload

echo "✅ İşlem tamamlandı: $DOMAIN zone'u $KEY_NAME ile güncellendi."
