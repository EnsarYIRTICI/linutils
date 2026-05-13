#!/bin/bash
set -euo pipefail
trap 'echo "❌ Bir hata oluştu. Komut: $BASH_COMMAND"; exit 1' ERR

# 🟢 Argümanlardan oku / prompt et
if [ -n "${1:-}" ]; then
  DOMAIN=$1
else
  read -p "Lütfen oluşturmak istediğiniz domain adını girin (örnek: example.com): " DOMAIN
fi

if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]+$ ]]; then
  echo "Geçersiz domain formatı. Örnek: example.com"
  exit 1
fi

if [ -n "${2:-}" ]; then
  IP=$2
else
  read -p "Lütfen domain için IP adresini girin: " IP
fi

if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Geçersiz IP adresi formatı."
  exit 1
fi

# 📂 Yol/degiskenler
TLD=$(awk -F. '{print $(NF)}' <<<"$DOMAIN")
ZONES_DIR="/etc/bind/zones/$TLD"
ZONE_FILE="$ZONES_DIR/db.${DOMAIN}"
ZONES_CONFIG_DIR="/etc/bind/zones-config"
NAMED_LOCAL="/etc/bind/named.conf.local"
INCLUDE_LINE="include \"${ZONES_CONFIG_DIR}/${TLD}.zones\";"

# 📁 Klasörler
sudo mkdir -p "$ZONES_DIR" "$ZONES_CONFIG_DIR"

# 🧩 named.conf.local'a include ekle (yoksa)
if ! grep -qF "$INCLUDE_LINE" "$NAMED_LOCAL" 2>/dev/null; then
  echo "🧩 include ekleniyor: $INCLUDE_LINE"
  echo "$INCLUDE_LINE" | sudo tee -a "$NAMED_LOCAL" >/dev/null
fi

# 🧱 ${TLD}.zones içine zone deklarasyonu (yoksa)
ZONES_LIST="${ZONES_CONFIG_DIR}/${TLD}.zones"
if ! grep -q "zone \"${DOMAIN}\"" "$ZONES_LIST" 2>/dev/null; then
  echo "📄 Zone tanımı ekleniyor: $DOMAIN"
  sudo tee -a "$ZONES_LIST" >/dev/null <<EOF
zone "$DOMAIN" {
    type master;
    file "$ZONE_FILE";
};
EOF
else
  echo "ℹ️  ${TLD}.zones içinde $DOMAIN zaten tanımlı, atlanıyor."
fi

# 🛠️ Zone dosyası oluştur/güncelle (tarih tabanlı serial)
SERIAL=$(date +%Y%m%d%H)
echo "🛠️  Zone dosyası yazılıyor: $ZONE_FILE"
sudo tee "$ZONE_FILE" >/dev/null <<EOF
\$TTL    604800
@       IN      SOA     ns1.${DOMAIN}. admin.${DOMAIN}. (
                              ${SERIAL}  ; Serial
                         604800          ; Refresh
                          86400          ; Retry
                        2419200          ; Expire
                         604800 )        ; Negative Cache TTL
;
@       IN      NS      ns1.${DOMAIN}.
@       IN      A       ${IP}
ns1     IN      A       ${IP}
www     IN      A       ${IP}
EOF

# 🔐 İzinler (bazı sistemlerde gerekli olabilir)
sudo chown root:bind "$ZONE_FILE" || true
sudo chmod 0644 "$ZONE_FILE" || true

# 🔍 Kontroller
echo "✅ Yapılandırma kontrol ediliyor..."
sudo named-checkconf
sudo named-checkzone "$DOMAIN" "$ZONE_FILE"

# 🔄 Yeni conf'u okut ve zone'u yüklet
sudo rndc reconfig
sudo rndc reload "$DOMAIN" || true

echo "✅ Zone başarıyla eklendi/güncellendi: $DOMAIN → $IP"
echo "🔍 Test önerisi:"
echo "    dig @10.8.0.1 ${DOMAIN} SOA +norecurse"
echo "    dig @10.8.0.1 ${DOMAIN} A   +norecurse"
