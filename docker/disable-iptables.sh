#!/usr/bin/env bash
set -euo pipefail

DAEMON_JSON="/etc/docker/daemon.json"

if [[ "$EUID" -ne 0 ]]; then
  echo "Bu scripti sudo/root ile çalıştır."
  exit 1
fi

echo "[*] /etc/docker dizini oluşturuluyor..."
mkdir -p /etc/docker

# Eski dosyayı yedekle
if [[ -f "$DAEMON_JSON" ]]; then
  BACKUP="${DAEMON_JSON}.$(date +%Y%m%d%H%M%S).bak"
  echo "[*] Mevcut daemon.json bulundu, yedekleniyor -> $BACKUP"
  cp "$DAEMON_JSON" "$BACKUP"
fi

echo "[*] daemon.json içine \"iptables\": false yazılıyor..."

python3 << 'PY'
import json, os, sys

path = "/etc/docker/daemon.json"
data = {}

# Eğer dosya varsa ve boş değilse JSON olarak oku
if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:
        print(f"[!] Mevcut daemon.json JSON değil, elle düzeltmen lazım: {e}", file=sys.stderr)
        sys.exit(1)

# iptables ayarını ekle/güncelle
data["iptables"] = False

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("[*] /etc/docker/daemon.json güncellendi.")
PY

echo "[*] Docker servisi yeniden başlatılıyor..."
systemctl restart docker

echo "[✓] İşlem bitti."
