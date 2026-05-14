#!/bin/bash

echo "[*] Split tunneling kurulum başlatılıyor..."

# 0. Kullanıcıdan VPN arayüzü ismi al
read -p "Hangi VPN arayüzü için split tunneling yapılsın? (örn: tun0, wg0): " VPN_IFACE
VPN_IFACE=${VPN_IFACE:-tun0}  # Kullanıcı bir şey girmezse varsayılan tun0 olur
echo "[*] Seçilen arayüz: $VPN_IFACE"

# 1. Kontrol scripti oluştur
cat <<EOF > /usr/local/bin/check-vpn-and-clean-routes.sh
#!/bin/bash

IFACE="$VPN_IFACE"
VPN_GATEWAY="10.8.0.1"

if ip link show \$IFACE up >/dev/null 2>&1 && ping -c 1 -W 2 \$VPN_GATEWAY >/dev/null 2>&1; then
    echo "[INFO] VPN aktif, varsayılan rotalar temizleniyor..."
    ip route del 0.0.0.0/1 dev \$IFACE 2>/dev/null
    ip route del 128.0.0.0/1 dev \$IFACE 2>/dev/null
else
    echo "[WARN] \$IFACE arayüzü aktif değil veya VPN gateway (\$VPN_GATEWAY) yanıt vermiyor."
fi
EOF

chmod +x /usr/local/bin/check-vpn-and-clean-routes.sh
echo "[+] /usr/local/bin/check-vpn-and-clean-routes.sh oluşturuldu."

# 2. systemd servis dosyası oluştur
cat <<EOF > /etc/systemd/system/vpn-route-cleaner.service
[Unit]
Description=Remove OpenVPN forced default routes if VPN is active on $VPN_IFACE
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-vpn-and-clean-routes.sh
EOF

echo "[+] vpn-route-cleaner.service oluşturuldu."

# 3. systemd timer dosyası oluştur
cat <<EOF > /etc/systemd/system/vpn-route-cleaner.timer
[Unit]
Description=Run VPN route cleaner every 5 seconds

[Timer]
OnBootSec=10
OnUnitActiveSec=5

[Install]
WantedBy=timers.target
EOF

echo "[+] vpn-route-cleaner.timer oluşturuldu."

# 4. systemd yeniden yükle ve timer'ı başlat
systemctl daemon-reload
systemctl enable --now vpn-route-cleaner.timer

echo "[✓] Timer etkinleştirildi ve başlatıldı."
echo "[✓] Kurulum tamamlandı. Durumu görmek için: systemctl status vpn-route-cleaner.timer"
