#!/bin/bash
set -euo pipefail
trap 'echo "❌ HATA: Komut başarısız oldu: $BASH_COMMAND (Satır: $LINENO)" >&2' ERR

# =============================
# Dynamic DNS Update Script
# =============================

ZONE="${1:-}"
NEW_IP="${2:-}"

# 🔹 Zone ismi eksikse iste
if [[ -z "$ZONE" ]]; then
    read -rp "🔹 Lütfen zone adını girin (örn: panel.msi): " ZONE
fi

# 🔹 IP eksikse iste
if [[ -z "$NEW_IP" ]]; then
    read -rp "🔹 Lütfen IP adresini girin (örn: 10.8.0.1): " NEW_IP
fi

# ✅ Zone encoding temizle (UTF-8 → ASCII, küçük harf, geçerli karakterler)
ZONE=$(echo "$ZONE" | iconv -f utf-8 -t ascii//TRANSLIT | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')
ZONE="${ZONE%.}"   # sonda nokta varsa kaldır

# ✅ IP adres format kontrolü
if [[ ! "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "❌ HATA: Geçersiz IP adresi formatı: $NEW_IP" >&2
    exit 1
fi

# ✅ Key ve zone dosya yolları
TLD="${ZONE##*.}"
KEY_NAME="ddns-${TLD}"
KEY_FILE="/etc/bind/keys/${KEY_NAME}.key"
ZONE_FILE="/etc/bind/zones/${TLD}/db.${ZONE}"

# 🔍 Key dosyası kontrolü
echo "🔍 Key dosyası kontrol ediliyor: $KEY_FILE"
if [[ ! -f "$KEY_FILE" ]]; then
    echo "❌ HATA: Key dosyası bulunamadı: $KEY_FILE" >&2
    exit 1
fi

# ✅ nsupdate komutlarını hazırla
TMP_FILE=$(mktemp)
{
    echo "server 127.0.0.1"
    echo "zone $ZONE"
    for sub in "" "www" "ns1"; do
        FQDN="${sub:+$sub.}$ZONE."
        echo "update delete $FQDN A"
        echo "update add $FQDN 3600 A $NEW_IP"
    done
    echo "send"
} > "$TMP_FILE"

# ⚡ DDNS güncellemesi
echo "📡 nsupdate gönderiliyor..."
if nsupdate -v -k "$KEY_FILE" < "$TMP_FILE"; then
    echo "✅ $ZONE için A kayıtları başarıyla $NEW_IP olarak güncellendi."
else
    echo "❌ HATA: nsupdate başarısız oldu." >&2
    rm -f "$TMP_FILE"
    exit 1
fi

rm -f "$TMP_FILE"

# ✅ BIND journal değişikliklerini zone dosyasına yaz
echo "🔄 Zone senkronize ediliyor..."
rndc sync -clean "$ZONE" 2>/dev/null || true

# 📄 Zone dosyasını göster
if [[ -f "$ZONE_FILE" ]]; then
    echo -e "\n📄 Güncellenen zone dosyası: $ZONE_FILE\n"
    cat "$ZONE_FILE"
else
    echo "⚠️ UYARI: Zone dosyası bulunamadı ($ZONE_FILE). BIND journal kullanıyor olabilir."
fi

# ✅ DNS kaydını test et
echo -e "\n🔍 Güncel DNS kaydı:"
dig @"127.0.0.1" "$ZONE" +short || true
