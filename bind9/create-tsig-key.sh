#!/bin/bash
set -euo pipefail
trap 'echo "❌ Bir hata oluştu. Komut: $BASH_COMMAND"; exit 1' ERR

# 🔐 Key adı sor
read -rp "🔐 Oluşturulacak TSIG key adı nedir? (örn: ddns-1): " KEY_NAME
KEY_NAME="${KEY_NAME:-ddns}"

# 📂 Klasör ve dosya yolları
KEY_DIR="/etc/bind/keys"
KEY_FILE="${KEY_DIR}/${KEY_NAME}.key"
NAMED_CONF="/etc/bind/named.conf.local"
INCLUDE_LINE="include \"${KEY_FILE}\";"

# 📁 Klasör yoksa oluştur
sudo mkdir -p "$KEY_DIR"

# ⚠️ Var olan key dosyası kontrolü
if [[ -f "$KEY_FILE" ]]; then
    echo "⚠️ $KEY_FILE zaten var. Üzerine yazmak ister misiniz? (e/h)"
    read -rn1 CONFIRM
    echo
    if [[ "$CONFIRM" != "e" && "$CONFIRM" != "E" ]]; then
        echo "❌ İşlem iptal edildi."
        exit 1
    fi
fi

# 🔧 TSIG key oluştur
echo "🔧 TSIG key oluşturuluyor: $KEY_NAME"
sudo tsig-keygen "$KEY_NAME" | sudo tee "$KEY_FILE" > /dev/null

# 🔐 Dosya izinlerini ayarla
sudo chown root:bind "$KEY_FILE"
sudo chmod 640 "$KEY_FILE"

# 📎 include satırını named.conf.local dosyasına ekle (varsa tekrar ekleme)
if ! grep -Fxq "$INCLUDE_LINE" "$NAMED_CONF"; then
    sudo sed -i "1i$INCLUDE_LINE" "$NAMED_CONF"
    echo "✅ include satırı eklendi: $INCLUDE_LINE"
else
    echo "ℹ️ include zaten mevcut: $INCLUDE_LINE"
fi

echo "✅ TSIG key başarıyla oluşturuldu: $KEY_FILE"
