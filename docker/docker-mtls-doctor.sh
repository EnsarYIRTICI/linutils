#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Docker mTLS Doktor (Soru–Cevap)
# ==============================
# Bu script, Docker daemon (sunucu) ve Portainer/istemci arasındaki mTLS sorunlarını
# adım adım SORU–CEVAP şeklinde teşhis eder ve gerekirse istemci sertifikasını yeniden üretir.
#
# Varsayılanlar:
TLS_DIR="/etc/docker/tls"
DOMAIN_DEFAULT="home.xenny.cloud"
DAEMON_JSON="/etc/docker/daemon.json"

# Renkler
BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"

hr() { echo -e "${DIM}------------------------------------------------------------${RESET}"; }
say() { echo -e "$*"; }
q()   { echo -en "${BOLD}?${RESET} $* "; }
ok()  { echo -e "${GREEN}✔${RESET} $*"; }
warn(){ echo -e "${YELLOW}!${RESET} $*"; }
err() { echo -e "${RED}✖${RESET} $*" >&2; }
press_enter(){ read -r -p "Devam etmek için Enter'a bas..."; }

need_bin(){
  command -v "$1" >/dev/null 2>&1 || { err "'$1' bulunamadı. Lütfen yükleyin."; exit 1; }
}

# 0) Ön kontroller
hr
say "${BOLD}Docker mTLS Doktor'a hoş geldin 👋${RESET}"
need_bin openssl
need_bin curl
say "OpenSSL ve curl bulundu."
hr

# 1) Klasör ve dosyalar
q "TLS dizini neresi? [varsayılan: ${TLS_DIR}]"
read -r input_dir || true
TLS_DIR="${input_dir:-$TLS_DIR}"

CA_PEM="${TLS_DIR}/ca.pem"
CA_KEY="${TLS_DIR}/ca.key"
SERVER_PEM="${TLS_DIR}/server.pem"
SERVER_KEY="${TLS_DIR}/server.key"
CLIENT_PEM="${TLS_DIR}/client.pem"
CLIENT_KEY="${TLS_DIR}/client.key"

for f in "$CA_PEM" "$CA_KEY" "$SERVER_PEM" "$SERVER_KEY"; do
  [[ -s "$f" ]] || { err "$f bulunamadı veya boş."; exit 1; }
done
ok "Temel dosyalar mevcut: ca.pem, ca.key, server.pem, server.key"

[[ -s "$CLIENT_PEM" && -s "$CLIENT_KEY" ]] && has_client=yes || has_client=no
if [[ "$has_client" == "yes" ]]; then
  ok "İstemci dosyaları mevcut: client.pem, client.key"
else
  warn "İstemci sertifikası/anahtarı eksik görünüyor; birazdan oluşturabilirsin."
fi
hr

# 2) Sunucu sertifikası – CA doğrulaması
say "${BOLD}Soru:${RESET} Sunucu sertifikası doğru CA ile imzalı mı?"
say "Kontrol: openssl verify -CAfile ca.pem server.pem"
if openssl verify -CAfile "$CA_PEM" "$SERVER_PEM" >/dev/null 2>&1; then
  ok "Sunucu sertifikası CA tarafından DOĞRULANDI."
else
  err "Sunucu sertifikası CA ile doğrulanamadı! (server.pem ↔ ca.pem uyuşmuyor)"
  say "Lütfen server.pem'i doğru CA ile yeniden imzalayın."
  exit 1
fi
hr

# 3) Sunucu sertifikası – SAN/FQDN
q "Docker daemon'a hangi domain ile bağlanıyorsun? [varsayılan: ${DOMAIN_DEFAULT}] "
read -r DOMAIN || true
DOMAIN="${DOMAIN:-$DOMAIN_DEFAULT}"

say "${BOLD}Soru:${RESET} Server SAN alanında '${DOMAIN}' var mı?"
if openssl x509 -in "$SERVER_PEM" -noout -text | grep -A1 -F "Subject Alternative Name" | grep -Eq "DNS: *${DOMAIN}\b"; then
  ok "SAN içinde ${DOMAIN} var."
else
  err "SAN içinde ${DOMAIN} yok! (server.pem yeniden imza gerekir)"
  say "SUNUCU sertifikasını, SAN'a '${DOMAIN}' (ve gerekiyorsa IP) ekleyerek yeniden üretin."
  exit 1
fi
hr

# 4) daemon.json ayarı
say "${BOLD}Soru:${RESET} docker daemon doğru TLS yollarını mı kullanıyor?"
if [[ -s "$DAEMON_JSON" ]]; then
  grep -n . "$DAEMON_JSON" || true
  say
  if grep -q '"tlsverify"\s*:\s*true' "$DAEMON_JSON" \
     && grep -q "\"tlscacert\"\\s*:\\s*\"${CA_PEM}\"" "$DAEMON_JSON" \
     && grep -q "\"tlscert\"\\s*:\\s*\"${SERVER_PEM}\"" "$DAEMON_JSON" \
     && grep -q "\"tlskey\"\\s*:\\s*\"${SERVER_KEY}\"" "$DAEMON_JSON"; then
    ok "daemon.json TLS alanları doğru görünüyor."
  else
    warn "daemon.json içinde beklenen TLS alanları farklı olabilir. Yolları kontrol et."
  fi
else
  warn "daemon.json bulunamadı; Docker varsayılanlarla çalışıyor olabilir."
fi
hr

# 5) İstemci sertifikası üretim (gerekliyse/istenirse)
regen=no
if [[ "$has_client" == "no" ]]; then
  regen=yes
else
  q "İstemci sertifikasını aynı CA ile (clientAuth EKU'yla) yeniden üretmek ister misin? [e/H] "
  read -r ans || true
  [[ "${ans:-e}" =~ ^[eEyY]$ ]] && regen=yes || regen=no
fi

if [[ "$regen" == "yes" ]]; then
  say "${BOLD}Soru:${RESET} İstemci sertifikasını yeniden üretiyorum, onaylıyor musun? [e/H]"
  read -r onay || true
  if [[ "${onay:-e}" =~ ^[eEyY]$ ]]; then
    mkdir -p "${TLS_DIR}/backup"
    cp -a "${TLS_DIR}/client."* "${TLS_DIR}/backup/" 2>/dev/null || true
    ok "Eski client.* dosyaları yedeklendi: ${TLS_DIR}/backup"

    openssl genrsa -out "$CLIENT_KEY" 4096
    openssl req -new -key "$CLIENT_KEY" -out "${TLS_DIR}/client.csr" -subj "/CN=portainer"

    cat > "${TLS_DIR}/client-ext.cnf" <<'EOF'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

    openssl x509 -req -in "${TLS_DIR}/client.csr" -CA "$CA_PEM" -CAkey "$CA_KEY" -CAcreateserial \
      -out "$CLIENT_PEM" -days 825 -sha256 -extfile "${TLS_DIR}/client-ext.cnf"

    if openssl verify -CAfile "$CA_PEM" "$CLIENT_PEM" >/dev/null 2>&1; then
      ok "İstemci sertifikası CA ile DOĞRULANDI."
    else
      err "İstemci sertifikası doğrulanamadı! (client.pem ↔ ca.pem uyuşmuyor)"
      exit 1
    fi
  else
    warn "İstemci sertifikası yeniden üretilmedi (mevcut olan kullanılacak)."
  fi
fi
hr

# 6) Sunucuya mTLS testleri (curl)
say "${BOLD}Soru:${RESET} Sadece CA ile (client serti yok) `_ping` denemesi → 403/handshake failure beklenir:"
set +e
curl -sS --max-time 10 --cacert "$CA_PEM" "https://${DOMAIN}:2376/_ping" -v 2>&1 | sed -e 's/^/> /'
rc1=$?
set -e
if [[ $rc1 -eq 0 ]]; then
  warn "CA ile istek başarılı görünüyor (bu normal değil, mTLS kapalı olabilir?)."
else
  ok "Beklenen şekilde doğrudan başarılı olmadı (mTLS muhtemelen açık)."
fi
hr

say "${BOLD}Soru:${RESET} CA + İstemci sertifikası ile `_ping` denemesi → 'OK' beklenir:"
set +e
RESP="$(curl -sS --max-time 10 --cacert "$CA_PEM" --cert "$CLIENT_PEM" --key "$CLIENT_KEY" "https://${DOMAIN}:2376/_ping" 2>/dev/null)"
rc2=$?
set -e
if [[ $rc2 -eq 0 && "$RESP" == "OK" ]]; then
  ok "mTLS testi BAŞARILI: Sunucu 'OK' döndü."
else
  err "mTLS testi BAŞARISIZ. curl çıkış kodu: $rc2, yanıt: '${RESP:-<boş>}'"
  warn "Sıklıkla görülen nedenler:"
  say "  - client.pem CA ile imzalı değil veya EKU=clientAuth yok."
  say "  - Port/dns farklı (DOMAIN yanlış)."
  say "  - Daemon başka bir ca.pem kullanıyor (daemon.json yolunu kontrol et, Docker'ı yeniden başlat)."
  hr
  say "Hızlı tanı komutları:"
  echo "  openssl x509 -in \"$CLIENT_PEM\" -noout -issuer -subject"
  echo "  openssl x509 -in \"$CLIENT_PEM\" -noout -text | sed -n '/Extended Key Usage/,+2p'"
  echo "  openssl x509 -in \"$SERVER_PEM\" -noout -text | sed -n '/Subject Alternative Name/,+1p'"
  exit 1
fi
hr

# 7) Özet & Portainer yönergesi
say "${BOLD}ÖZET${RESET}"
ok "Sunucu sertifikası doğru CA ile doğrulandı ve SAN '${DOMAIN}'."
ok "İstemci sertifikası CA tarafından doğrulandı (clientAuth EKU)."
ok "curl ile mTLS üzerinden Docker API 'OK' döndürdü."

say
say "${BOLD}Portainer için:${RESET}"
say "  Environments → Add/Edit → Agent değil, ${BOLD}Docker (standalone/remote)${RESET} seç."
say "  ${BOLD}Security / TLS${RESET}:"
say "    - TLS CA certificate  → ${CA_PEM} (içeriği)"
say "    - TLS client certificate → ${CLIENT_PEM} (içeriği)"
say "    - TLS client key → ${CLIENT_KEY} (içeriği)"
say "  Endpoint URL: https://${DOMAIN}:2376"
hr
say "${GREEN}Tüm adımlar tamam. İyi çalışmalar! 🚀${RESET}"
