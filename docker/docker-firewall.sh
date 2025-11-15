#!/usr/bin/env bash
set -euo pipefail

CHAIN="DOCKER-USER"
WAN_IFACE="eth0"
DOCKER_NETS=("172.17.0.0/16" "172.18.0.0/16")

log() {
  # Basit log fonksiyonu
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

usage() {
  cat <<EOF
Kullanım: $0 {apply|restore|status}

  apply    : Docker için kısıtlayıcı firewall kurallarını uygular
  restore  : Kuralları geri alır, DOCKER-USER zincirini varsayılan duruma çeker
  status   : DOCKER-USER zincirindeki mevcut kuralları gösterir

Not: Root olarak çalıştırmalısınız (sudo ile).
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Bu script root olarak çalıştırılmalıdır (sudo kullanın)." >&2
    exit 1
  fi
}

require_iptables() {
  if ! command -v iptables >/dev/null 2>&1; then
    echo "iptables komutu bulunamadı. Bu script yalnızca iptables (IPv4) için yazıldı." >&2
    exit 1
  fi
}

ensure_chain() {
  if iptables -nL "$CHAIN" >/dev/null 2>&1; then
    log "$CHAIN zinciri mevcut."
  else
    log "$CHAIN zinciri yok, oluşturuluyor..."
    iptables -N "$CHAIN"
    # FORWARD zincirine ekleyelim ki trafik buradan geçsin
    iptables -C FORWARD -j "$CHAIN" >/dev/null 2>&1 || iptables -I FORWARD -j "$CHAIN"
  fi
}

apply_rules() {
  log "[$CHAIN] kuralları uygulanıyor..."

  ensure_chain

  # Mevcut kuralları temizle
  log "Mevcut $CHAIN kuralları temizleniyor..."
  iptables -F "$CHAIN"

  # Docker internal network'lere izin ver
  for NET in "${DOCKER_NETS[@]}"; do
    log "Internal Docker ağına izin veriliyor: ${NET}"
    iptables -A "$CHAIN" -s "$NET" -j ACCEPT
  done

  # Docker'dan WAN interface üzerinden yeni outbound bağlantılara izin ver
  log "Yeni outbound bağlantılara izin veriliyor: -o ${WAN_IFACE}"
  iptables -A "$CHAIN" -m conntrack --ctstate NEW -o "$WAN_IFACE" -j ACCEPT

  # İlgili / kurulmuş bağlantıların geri dönüş paketlerine izin ver
  log "RELATED,ESTABLISHED bağlantılara izin veriliyor..."
  iptables -A "$CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  # Geri kalan her şeyi DROP et
  log "Geri kalan tüm trafiğe DROP uygulanıyor..."
  iptables -A "$CHAIN" -j DROP

  log "[$CHAIN] firewall kuralları başarıyla uygulandı."
}

restore_rules() {
  log "[$CHAIN] kuralları geri alınıyor (restore)..."

  if ! iptables -nL "$CHAIN" >/dev/null 2>&1; then
    log "$CHAIN zinciri bulunamadı, yapacak bir şey yok."
    return 0
  fi

  # Zincirdeki tüm kuralları temizle
  log "$CHAIN zinciri temizleniyor..."
  iptables -F "$CHAIN"

  # İsteğe bağlı: geri üst zincire dönmesi için RETURN kuralı ekle
  # (Varsayılan davranış: DOCKER-USER trafiği bloklamasın)
  if ! iptables -C "$CHAIN" -j RETURN >/dev/null 2>&1; then
    log "$CHAIN zincirine RETURN kuralı ekleniyor..."
    iptables -A "$CHAIN" -j RETURN
  fi

  log "[$CHAIN] zinciri varsayılan, müdahale etmeyen moda alındı."
}

status_rules() {
  if iptables -nL "$CHAIN" >/dev/null 2>&1; then
    echo "==== iptables -L $CHAIN -n -v --line-numbers ===="
    iptables -L "$CHAIN" -n -v --line-numbers
  else
    echo "$CHAIN zinciri mevcut değil."
  fi
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"

  require_root
  require_iptables

  case "$cmd" in
    apply)
      apply_rules
      ;;
    restore)
      restore_rules
      ;;
    status)
      status_rules
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
