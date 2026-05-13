#!/usr/bin/env bash

set -e

# DNS listesi (istersen değiştir)
DNS_SERVERS="8.8.8.8 1.1.1.1"

# Aktif bağlantıyı bul
CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | head -n1 | cut -d: -f1)

if [ -z "$CON_NAME" ]; then
  echo "Aktif bağlantı bulunamadı"
  exit 1
fi

echo "Aktif bağlantı: $CON_NAME"

# DNS ayarla ve otomatik DNS'i kapat
nmcli connection modify "$CON_NAME" ipv4.dns "$DNS_SERVERS"
nmcli connection modify "$CON_NAME" ipv4.ignore-auto-dns yes

# Bağlantıyı yenile
nmcli connection down "$CON_NAME"
nmcli connection up "$CON_NAME"

echo "DNS başarıyla güncellendi: $DNS_SERVERS"