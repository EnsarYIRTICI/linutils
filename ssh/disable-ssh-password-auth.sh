#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[LOCAL][INFO]  $*"; }
warn() { echo "[LOCAL][WARN]  $*" >&2; }
err()  { echo "[LOCAL][ERROR] $*" >&2; }

CONF="/etc/ssh/sshd_config"
CONF_D="/etc/ssh/sshd_config.d"
BACKUP_SUFFIX="$(date +'%Y%m%d_%H%M%S')"

# Root değilsek kendimizi sudo ile tekrar çalıştır
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

ensure_include() {
  mkdir -p "$CONF_D"
  if ! grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$CONF"; then
    backup "$CONF"
    echo 'Include /etc/ssh/sshd_config.d/*.conf' >> "$CONF"
    log "Include eklendi: $CONF -> $CONF_D/*.conf"
  else
    log "Include satırı zaten var."
  fi
}

write_override() {
  mkdir -p "$CONF_D"
  local ovr="$CONF_D/99-disable-passwords.conf"
  backup "$ovr" || true

  cat > "$ovr" <<EOF
# Bu dosya parola ile SSH girişini kapatmak için otomatik oluşturuldu.
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
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
  if "$sshd_bin" -t -f "$CONF"; then
    log "sshd -t başarılı."
  else
    err "sshd -t başarısız! Gerekirse ${CONF}.${BACKUP_SUFFIX} ve conf.d yedeklerinden geri alın."
    exit 2
  fi
}

restart_ssh() {
  log "SSH servisi yeniden başlatılıyor..."

  local restart_ok=0

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart sshd 2>/dev/null; then
      log "systemctl restart sshd başarılı"
      restart_ok=1
    elif systemctl restart ssh 2>/dev/null; then
      log "systemctl restart ssh başarılı"
      restart_ok=1
    fi
  fi

  if [[ $restart_ok -eq 0 ]]; then
    if command -v service >/dev/null 2>&1; then
      if service sshd restart 2>/dev/null; then
        log "service sshd restart başarılı"
        restart_ok=1
      elif service ssh restart 2>/dev/null; then
        log "service ssh restart başarılı"
        restart_ok=1
      fi
    fi
  fi

  sleep 2

  if [[ $restart_ok -eq 1 ]]; then
    log "SSH servisi yeniden başlatıldı."
  else
    err "SSH servisi yeniden başlatılamadı! Elle kontrol et."
    exit 3
  fi
}

verify_effective_config() {
  local sshd_bin
  sshd_bin="$(command -v sshd || command -v /usr/sbin/sshd || true)"
  [[ -n "$sshd_bin" ]] || return 0

  log "Etkin SSH konfigürasyonu kontrol ediliyor..."
  local eff
  eff="$("$sshd_bin" -T 2>/dev/null || true)"

  echo "$eff" | awk 'BEGIN{IGNORECASE=1} /passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|pubkeyauthentication|authenticationmethods/{print "[LOCAL][EFFECTIVE] "$0}'

  if echo "$eff" | grep -qi "passwordauthentication yes"; then
    warn "Etkin konfigürasyonda hâlâ PasswordAuthentication yes görünüyor!"
    warn "Muhtemelen farklı bir Match bloğu vs. override ediyor, manuel incele."
  else
    log "✅ Etkin konfigürasyonda PasswordAuthentication no görünüyor."
  fi
}

### Ana akış
log "SSH parola ile giriş kapatma işlemi başlıyor..."
ensure_include
write_override
test_sshd_config
restart_ssh
verify_effective_config
log "✅ İşlem tamamlandı. Public key ile giriş açık, parola ile giriş kapalı."
