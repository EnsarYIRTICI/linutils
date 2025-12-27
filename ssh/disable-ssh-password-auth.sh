#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[LOCAL][INFO]  $*"; }
warn() { echo "[LOCAL][WARN]  $*" >&2; }
err()  { echo "[LOCAL][ERROR] $*" >&2; }

CONF="/etc/ssh/sshd_config"
CONF_D="/etc/ssh/sshd_config.d"
BACKUP_SUFFIX="$(date +'%Y%m%d_%H%M%S')"
INCLUDE_LINE='Include /etc/ssh/sshd_config.d/*.conf'

if [[ $EUID -ne 0 ]]; then
  log "Root değilsin, sudo ile yeniden başlatıyorum..."
  exec sudo bash "$0" "$@"
fi

[[ -f "$CONF" ]] || { err "Bulunamadı: $CONF"; exit 1; }

backup() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.${BACKUP_SUFFIX}"
    log "Yedek alındı: ${f}.${BACKUP_SUFFIX}"
  fi
}

ensure_final_include() {
  mkdir -p "$CONF_D"
  # Dosyada Include var mı?
  if ! grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$CONF"; then
    backup "$CONF"
    printf "\n%s\n" "$INCLUDE_LINE" >> "$CONF"
    log "Include eklendi (yoktu): $INCLUDE_LINE"
    return
  fi

  # Include var ama en sonda mı? (son anlamlı satır include değilse en sona bir tane daha ekle)
  local last_meaningful
  last_meaningful="$(grep -Ev '^\s*($|#)' "$CONF" | tail -n 1 || true)"
  if [[ "$last_meaningful" != "$INCLUDE_LINE" ]]; then
    backup "$CONF"
    printf "\n# Ensure sshd_config.d overrides are applied last\n%s\n" "$INCLUDE_LINE" >> "$CONF"
    log "Include en sona da eklendi (override'lar en son uygulansın diye)."
  else
    log "Include zaten dosyanın sonunda."
  fi
}

neutralize_known_enable_file() {
  # Daha önce benim verdiğim enable dosyası varsa, disable et (silmek yerine rename)
  local f="$CONF_D/00-enable-passwords.conf"
  if [[ -f "$f" ]]; then
    backup "$f"
    mv -f "$f" "${f}.disabled"
    log "Çakışan enable dosyası devre dışı bırakıldı: ${f}.disabled"
  fi
}

write_disable_override() {
  mkdir -p "$CONF_D"
  # En sona gelmesi için 99zz...
  local ovr="$CONF_D/99zz-disable-passwords.conf"
  backup "$ovr" || true

  cat > "$ovr" <<'EOF'
# Parola ile SSH girişini kapatmak için otomatik oluşturuldu.
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

# Sadece publickey ile giriş
AuthenticationMethods publickey
EOF

  log "Override yazıldı: $ovr"
}

test_sshd_config() {
  local sshd_bin
  sshd_bin="$(command -v sshd || command -v /usr/sbin/sshd || true)"
  if [[ -z "$sshd_bin" ]]; then
    warn "sshd binary bulunamadı, sözdizimi testi atlanıyor."
    return 0
  fi

  log "sshd konfigürasyonu test ediliyor..."
  "$sshd_bin" -t -f "$CONF"
  log "sshd -t başarılı."
}

restart_ssh() {
  log "SSH servisi yeniden başlatılıyor..."

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
  else
    service sshd restart 2>/dev/null || service ssh restart 2>/dev/null
  fi

  log "SSH servisi yeniden başlatıldı."
}

verify_effective_config() {
  local sshd_bin
  sshd_bin="$(command -v sshd || command -v /usr/sbin/sshd || true)"
  [[ -n "$sshd_bin" ]] || return 0

  log "Etkin SSH konfigürasyonu kontrol ediliyor (Match etkilerini de görmek için -C ile)..."
  local eff
  eff="$("$sshd_bin" -T -f "$CONF" -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"

  echo "$eff" | awk 'BEGIN{IGNORECASE=1} /passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|pubkeyauthentication|authenticationmethods/{print "[LOCAL][EFFECTIVE] "$0}'

  if echo "$eff" | grep -qi "passwordauthentication no"; then
    log "✅ Etkin konfigürasyonda PasswordAuthentication no."
  else
    warn "❌ Etkin konfigürasyonda PasswordAuthentication no görünmüyor!"
    warn "Şunları çalıştırıp 'yes' basan satırı bul: "
    warn "grep -RniE '^(\\s*)(PasswordAuthentication|AuthenticationMethods|KbdInteractiveAuthentication|ChallengeResponseAuthentication)\\b' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf"
    exit 4
  fi
}

log "SSH parola ile giriş KAPATMA (force) işlemi başlıyor..."
ensure_final_include
neutralize_known_enable_file
write_disable_override
test_sshd_config
restart_ssh
verify_effective_config
log "✅ İşlem tamamlandı. Parola kapalı, public key açık."
