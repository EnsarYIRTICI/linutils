#!/bin/bash
set -euo pipefail
trap 'echo "❌ Beklenmeyen bir hata oluştu: $BASH_COMMAND (Satır: $LINENO)" >&2; exit 1' ERR

# 🔧 Debug modu: 1 → aktif, 0 → pasif
DEBUG=0

# Argümanlar: 1 = TLD, 2 = Yeni IP
TLD="${1:-}"
NEW_IP="${2:-}"

# Eksikse kullanıcıdan al
if [[ -z "$TLD" ]]; then
    read -rp "🔹 Lütfen güncellenecek TLD'yi girin (örn: com): " TLD
fi

if [[ -z "$NEW_IP" ]]; then
    read -rp "🔹 Lütfen yeni IP adresini girin: " NEW_IP
fi

# IP format doğrulama
if [[ ! "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "❌ HATA: Geçersiz IP adresi: $NEW_IP"
    exit 1
fi

# Dosya yolları
ZONES_FILE="/etc/bind/zones-config/${TLD}.zones"
KEY_FILE="/etc/bind/keys/ddns-${TLD}.key"

# Kontroller
if [[ ! -f "$ZONES_FILE" ]]; then
    echo "❌ HATA: Zone listesi dosyası yok: $ZONES_FILE"
    exit 1
fi

if [[ ! -f "$KEY_FILE" ]]; then
    echo "❌ HATA: Key dosyası bulunamadı: $KEY_FILE"
    exit 1
fi

echo "🔍 TLD '$TLD' için zone'lar okunuyor..."
ZONES=($(grep 'zone "' "$ZONES_FILE" | awk -F'"' '{print $2}'))

if [[ ${#ZONES[@]} -eq 0 ]]; then
    echo "❌ HATA: '$TLD' için tanımlı hiçbir zone bulunamadı."
    exit 1
fi

echo "🛠️  Aşağıdaki zone'lar güncellenecek:"
for z in "${ZONES[@]}"; do echo " - $z"; done
echo

# ✅ Hata sayacı
ERROR_COUNT=0

# Her zone için IP güncelle
for ZONE in "${ZONES[@]}"; do
    echo "🌐 $ZONE güncelleniyor..."

    TMP_FILE="/tmp/nsupdate_${ZONE}.txt"
    > "$TMP_FILE"
    echo "server 127.0.0.1" >> "$TMP_FILE"

    for sub in "" "www" "ns1"; do
        FQDN="${sub:+$sub.}$ZONE."
        echo "update delete $FQDN A" >> "$TMP_FILE"
        echo "update add $FQDN 3600 A $NEW_IP" >> "$TMP_FILE"
    done

    echo "send" >> "$TMP_FILE"

    if [[ "$DEBUG" -eq 1 ]]; then
        echo "🔍 [DEBUG] nsupdate komutu çalıştırılıyor (debug mod): $ZONE"
        nsupdate_cmd="nsupdate -d -k \"$KEY_FILE\" < \"$TMP_FILE\""
    else
        nsupdate_cmd="nsupdate -k \"$KEY_FILE\" < \"$TMP_FILE\""
    fi

    if eval "$nsupdate_cmd"; then
        echo "✅ $ZONE güncellendi."
    else
        echo "❌ HATA: $ZONE için nsupdate başarısız oldu!" >&2
        if [[ "$DEBUG" -eq 1 ]]; then
            echo "📄 [DEBUG] $TMP_FILE içeriği:"
            cat "$TMP_FILE"
        fi
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
done

echo

if [[ $ERROR_COUNT -eq 0 ]]; then
    echo "🎉 İşlem tamamlandı. '$TLD' son ekine sahip tüm zone'lar $NEW_IP adresine yönlendirildi."
else
    echo "⚠️  $ERROR_COUNT zone güncellenemedi. Lütfen logları inceleyin."
    exit 1
fi
