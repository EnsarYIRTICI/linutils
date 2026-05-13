#!/bin/bash
# ===========================================================
# BIND9 Kurulum ve Zone Yapılandırma Scripti
# ===========================================================

set -e

echo "🔹 BIND9 kurulumu başlatılıyor..."
apt update && apt install -y bind9 bind9utils bind9-doc dnsutils

echo "🔹 Gerekli dizinler oluşturuluyor..."
mkdir -p /etc/bind/zones
mkdir -p /etc/bind/zones-config
mkdir -p /etc/bind/keys

echo "🔹 Örnek zone ve key dosyaları oluşturuluyor (varsa atlanacak)..."
touch /etc/bind/zones/msi/db.example.msi
touch /etc/bind/zones-config/msi.zones
touch /etc/bind/keys/ddns-msi.key

echo "🔹 Sahiplik ayarlanıyor..."
chown -R bind:bind /etc/bind/zones /etc/bind/zones-config /etc/bind/keys

echo "🔹 Dizin izinleri ayarlanıyor..."
chmod 750 /etc/bind/zones
chmod 750 /etc/bind/zones-config
chmod 700 /etc/bind/keys

echo "🔹 Zone dosyaları için güvenli izinler..."
find /etc/bind/zones -type f -exec chmod 640 {} \;

echo "🔹 Key dosyaları için güvenli izinler..."
find /etc/bind/keys -type f -exec chmod 600 {} \;

echo "🔹 BIND yapılandırması kontrol ediliyor..."
named-checkconf || { echo "❌ HATA: named-checkconf başarısız"; exit 1; }

echo "🔹 BIND servisi yeniden başlatılıyor..."
systemctl enable bind9
systemctl restart bind9

echo "✅ Kurulum tamamlandı. BIND9 çalışıyor!"
systemctl status bind9 --no-pager
