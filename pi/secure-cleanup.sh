#!/bin/bash

echo "[+] Cloud-init / provisioning cleanup başlıyor..."

# cloud-init state temizle
sudo cloud-init clean --logs

# Wi-Fi provisioning dosyalarını sil (boot partition mount ise)
sudo rm -f /boot/user-data
sudo rm -f /boot/network-config
sudo rm -f /boot/wpa_supplicant.conf

# cloud-init tekrar çalışmasın diye disable
sudo touch /etc/cloud/cloud-init.disabled

# history temizle (opsiyonel)
history -c

echo "[+] Cleanup tamamlandı"