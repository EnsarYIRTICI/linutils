#!/usr/bin/env bash
# reach-gateway-gw-side.sh
# tin-gateway makinesinde calisir.
# VPN clientlarinin (tin uzerinden) bu makinenin eth1'ine ve
# arkasinaki LAN'a erisebilmesi icin gerekli ayarlari yapar.
#
# Senaryo:
#   [VPN Client]
#       |  tun0 (10.8.0.x)
#   [tin - VPN Server]
#       |  tun0 (10.8.0.1 <-> 10.8.0.2)
#   [tin-gateway]  <-- bu script BURADA calisir
#       |  eth1 (10.77.3.3/20)
#       |
#   [10.77.0.0/20 LAN]
#
# Kullanimlar:
#   sudo ./reach-gateway-gw-side.sh
#   sudo ./reach-gateway-gw-side.sh --lan 10.77.0.0/20 --tun tun0 --lan-iface eth1
#   sudo ./reach-gateway-gw-side.sh --lan 10.77.0.0/20 --tun tun0 --lan-iface eth1 --save yes
#   sudo ./reach-gateway-gw-side.sh --lan 10.77.0.0/20 --tun tun0 --lan-iface eth1 --rollback

set -euo pipefail

# ---- defaults ----
# Otomatik tespit edilebilir degerler, override edilebilir
LAN_CIDR="${LAN_CIDR:-}"
VPN_TUN="${VPN_TUN:-tun0}"
LAN_IFACE="${LAN_IFACE:-}"       # eth1 gibi — bos birakilirsa otomatik tespit
VPN_SERVER_IP="${VPN_SERVER_IP:-}"  # tin'in tun IP'si (10.8.0.1) — otomatik tespit
MASQUERADE="${MASQUERADE:-yes}"  # LAN cihazlarinda VPN route yoksa yes olmali
SAVE="${SAVE:-no}"
ROLLBACK="${ROLLBACK:-no}"

SYSCTL_FILE="/etc/sysctl.d/99-vpn-gw-side.conf"
IPTABLES_HOOK="/etc/network/if-up.d/vpn-gw-side-iptables"

# ---- renkler ----
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }

usage() {
  cat <<EOF

${BOLD}reach-gateway-gw-side.sh${NC}
  tin-gateway makinesinde VPN erisimini aktif eder.

${BOLD}Kullanim:${NC}
  sudo $0 [SECENEKLER]

${BOLD}Opsiyonel (otomatik tespit edilir):${NC}
  --lan CIDR              Hedef LAN                (varsayilan: eth1'den otomatik)
  --tun IFACE             VPN tunnel arayuzu       (varsayilan: tun0)
  --lan-iface IFACE       LAN arayuzu              (varsayilan: otomatik tespit)
  --vpn-server-ip IP      tin'in tun IP'si         (varsayilan: otomatik tespit)
  --masquerade yes|no     LAN icin MASQUERADE       (varsayilan: yes)
  --save yes|no           Kalici yap               (varsayilan: no)
  --rollback              Yapilan degisiklikleri geri al
  -h, --help              Bu mesaj

${BOLD}Ornek:${NC}
  sudo $0 --save yes
  sudo $0 --lan 10.77.0.0/20 --tun tun0 --lan-iface eth1 --save yes

EOF
  exit 0
}

# ---- arg parse ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan)            LAN_CIDR="$2";       shift 2;;
    --tun)            VPN_TUN="$2";        shift 2;;
    --lan-iface)      LAN_IFACE="$2";      shift 2;;
    --vpn-server-ip)  VPN_SERVER_IP="$2";  shift 2;;
    --masquerade)     MASQUERADE="$2";     shift 2;;
    --save)           SAVE="$2";           shift 2;;
    --rollback)       ROLLBACK="yes";      shift;;
    -h|--help)        usage;;
    *) die "Bilinmeyen arg: $1  (--help ile kullanim goster)";;
  esac
done

# ---- root kontrolu ----
[[ $EUID -eq 0 ]] || die "Root olarak calistir: sudo $0 ..."

# ---- komut kontrolu ----
for cmd in iptables ip sysctl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "Gerekli komut bulunamadi: $cmd"
done

# ---- yardimcilar ----

normalize_cidr() {
  python3 - "$1" <<'PY'
import sys, ipaddress
try:
    n = ipaddress.ip_network(sys.argv[1], strict=False)
    print(str(n))
except Exception as e:
    print(f"ERR:{e}", file=sys.stderr); sys.exit(1)
PY
}

ipt_check_add() {
  local new_rule=()
  local replaced=0
  for arg in "$@"; do
    if [[ "$arg" == "-C" && $replaced -eq 0 ]]; then
      new_rule+=("-A"); replaced=1
    else
      new_rule+=("$arg")
    fi
  done
  if iptables "$@" 2>/dev/null; then
    return 1  # zaten vardi
  fi
  iptables "${new_rule[@]}"
  return 0
}

ipt_delete_if_exists() {
  local del_rule=()
  local replaced=0
  for arg in "$@"; do
    if [[ "$arg" == "-C" && $replaced -eq 0 ]]; then
      del_rule+=("-D"); replaced=1
    else
      del_rule+=("$arg")
    fi
  done
  while iptables "$@" 2>/dev/null; do
    iptables "${del_rule[@]}" 2>/dev/null || break
  done
}

# tun0 arayzunun peer IP'sini (tin = VPN server) bul
auto_detect_vpn_server_ip() {
  # tun arayuzunun diger ucundaki IP = POINTOPOINT destination
  ip addr show "$VPN_TUN" 2>/dev/null | \
    awk '/inet / {split($4,a,"/"); if(a[1]!="") print a[1]; else split($2,b,"/"); print b[1]}' | \
    head -1 || true
  # Daha guvenilir yontem: routing table uzerinden tin'e giden next-hop
  # (tun point-to-point oldugu icin peer IP bazen "peer" keyword ile gelir)
}

# tun0 peer IP'sini ip route ile bul
auto_detect_vpn_server_ip_via_route() {
  # tin sunucusu genellikle VPN subnet'inin .1'idir
  local tun_ip
  tun_ip=$(ip addr show "$VPN_TUN" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]}' | head -1)
  if [[ -n "$tun_ip" ]]; then
    # .2 -> .1 gibi, son okteti 1 yap (basit heuristik)
    echo "${tun_ip%.*}.1"
  fi
}

# LAN arayuzunu otomatik tespit et (tun ve lo disindaki ilk UP arayuz)
auto_detect_lan_iface() {
  ip -o link show | awk -F': ' '
    $2 != "lo" && $2 !~ /^tun/ && $2 !~ /^docker/ && $2 !~ /^br-/ && $2 !~ /^veth/ {
      if ($0 ~ /state UP/) print $2
    }' | head -1
}

# Belirtilen arayuzun CIDR adresini al
iface_cidr() {
  ip addr show "$1" 2>/dev/null | awk '/inet / {print $2; exit}'
}

# ===========================================================
# ROLLBACK
# ===========================================================
do_rollback() {
  info "Rollback basliyor..."

  # LAN arayuzunu bul
  local lan_iface="${LAN_IFACE:-$(auto_detect_lan_iface)}"
  local lan_cidr="${LAN_CIDR:-$(iface_cidr "$lan_iface" 2>/dev/null || echo "")}"
  [[ -n "$lan_cidr" ]] && lan_cidr=$(normalize_cidr "$lan_cidr")
  local vpn_server_ip="${VPN_SERVER_IP:-$(auto_detect_vpn_server_ip_via_route)}"

  # 1. iptables kurallari kaldir
  if [[ -n "$lan_iface" && -n "$lan_cidr" ]]; then
    ipt_delete_if_exists -C FORWARD -i "$VPN_TUN" -o "$lan_iface" \
      -d "$lan_cidr" -j ACCEPT 2>/dev/null || true
    ipt_delete_if_exists -C FORWARD -i "$lan_iface" -o "$VPN_TUN" \
      -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    if [[ "${MASQUERADE,,}" == "yes" ]]; then
      ipt_delete_if_exists -t nat -C POSTROUTING -o "$lan_iface" \
        -d "$lan_cidr" -j MASQUERADE 2>/dev/null || true
    fi
    ok "iptables kurallari kaldirildi (varsa)"
  else
    warn "LAN arayuzu/CIDR tespit edilemedi, iptables rollback atlanıyor"
    warn "Elle: iptables -D FORWARD ... ve iptables -t nat -D POSTROUTING ..."
  fi

  # 2. iptables hook dosyasini kaldir
  if [[ -f "$IPTABLES_HOOK" ]]; then
    rm -f "$IPTABLES_HOOK"
    ok "Kalici iptables hook kaldirildi: $IPTABLES_HOOK"
  fi

  # 3. sysctl dosyasini kaldir
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>/dev/null || true
    ok "sysctl dosyasi kaldirildi, ip_forward=0 yapildi"
    warn "ip_forward=0 yapildi — baska bir servis gerektiriyorsa tekrar aktif edin"
  fi

  ok "Rollback tamamlandi."
  exit 0
}

[[ "$ROLLBACK" == "yes" ]] && do_rollback

# ===========================================================
# OTOMATIK TESPIT
# ===========================================================

# tun0 var mi?
ip link show "$VPN_TUN" >/dev/null 2>&1 || \
  die "VPN tunnel arayuzu bulunamadi: $VPN_TUN (OpenVPN bu makinede de calisiyor mu?)"

# LAN arayuzunu tespit et
if [[ -z "$LAN_IFACE" ]]; then
  LAN_IFACE=$(auto_detect_lan_iface)
  [[ -n "$LAN_IFACE" ]] || die "LAN arayuzu otomatik tespit edilemedi. --lan-iface ile belirtin."
  info "Otomatik tespit edilen LAN arayuzu: $LAN_IFACE"
fi

ip link show "$LAN_IFACE" >/dev/null 2>&1 || die "Arayuz bulunamadi: $LAN_IFACE"

# LAN CIDR'i tespit et
if [[ -z "$LAN_CIDR" ]]; then
  LAN_CIDR_RAW=$(iface_cidr "$LAN_IFACE")
  [[ -n "$LAN_CIDR_RAW" ]] || die "$LAN_IFACE uzerinde IP adresi yok. --lan ile belirtin."
  LAN_CIDR=$(normalize_cidr "$LAN_CIDR_RAW")
  info "Otomatik tespit edilen LAN CIDR: $LAN_CIDR"
else
  LAN_CIDR=$(normalize_cidr "$LAN_CIDR")
fi

# VPN server IP'yi tespit et
if [[ -z "$VPN_SERVER_IP" ]]; then
  VPN_SERVER_IP=$(auto_detect_vpn_server_ip_via_route)
  [[ -n "$VPN_SERVER_IP" ]] || die "VPN server IP otomatik tespit edilemedi. --vpn-server-ip ile belirtin."
  info "Otomatik tespit edilen VPN server IP (tin): $VPN_SERVER_IP"
fi

# tun0'in kendi IP'si
TUN_IP=$(ip addr show "$VPN_TUN" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]}' | head -1)
[[ -n "$TUN_IP" ]] || die "$VPN_TUN uzerinde IP adresi yok."

echo ""
info "Yapilandirma"
info "  Bu makine (tun IP)  : $TUN_IP"
info "  VPN Server (tin)    : $VPN_SERVER_IP"
info "  VPN tunnel          : $VPN_TUN"
info "  LAN arayuzu         : $LAN_IFACE"
info "  LAN CIDR            : $LAN_CIDR"
info "  MASQUERADE          : $MASQUERADE"
info "  Kaydet              : $SAVE"
echo ""

# ===========================================================
# 1. ip_forward
# ===========================================================
info "[1/4] ip_forward aktif ediliyor..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q 'net.ipv4.ip_forward=1' "$SYSCTL_FILE" 2>/dev/null; then
  echo 'net.ipv4.ip_forward=1' > "$SYSCTL_FILE"
  ok "  $SYSCTL_FILE yazildi (kalici)"
else
  ok "  ip_forward zaten aktif"
fi

# ===========================================================
# 2. iptables: FORWARD (tun0 -> eth1 ve geri donus)
# ===========================================================
info "[2/4] iptables FORWARD kurallari ekleniyor..."

# VPN'den LAN'a giden paketlere izin ver
R1=(-C FORWARD -i "$VPN_TUN" -o "$LAN_IFACE" -d "$LAN_CIDR" -j ACCEPT)
if ipt_check_add "${R1[@]}"; then
  ok "  FORWARD (${VPN_TUN} -> ${LAN_IFACE}, dst: $LAN_CIDR) eklendi"
else
  ok "  FORWARD (${VPN_TUN} -> ${LAN_IFACE}, dst: $LAN_CIDR) zaten mevcut"
fi

# LAN'dan VPN'e donus paketlerine izin ver (ESTABLISHED/RELATED)
R2=(-C FORWARD -i "$LAN_IFACE" -o "$VPN_TUN" -m state --state RELATED,ESTABLISHED -j ACCEPT)
if ipt_check_add "${R2[@]}"; then
  ok "  FORWARD (${LAN_IFACE} -> ${VPN_TUN}, ESTABLISHED/RELATED) eklendi"
else
  ok "  FORWARD (${LAN_IFACE} -> ${VPN_TUN}, ESTABLISHED/RELATED) zaten mevcut"
fi

# ===========================================================
# 3. iptables: MASQUERADE (opsiyonel)
# ===========================================================
info "[3/4] MASQUERADE kurali..."

# MASQUERADE ne zaman gerekli?
# - LAN icindeki cihazlar VPN network'une nasil route edeceklerini bilmiyorlarsa
#   (yani LAN gatewayinde "10.8.0.0/24 via 10.77.3.3" gibi bir route yoksa)
# - Bu durumda tin-gateway kaynak IP'yi kendi eth1 IP'si ile degistirir,
#   LAN cihazlari normal eth1 IP'sine cevap verir, geri donus olur.
# --masquerade no yapabilirsin eger LAN'daki router/switch bu routing'i biliyor ise.

if [[ "${MASQUERADE,,}" == "yes" ]]; then
  R3=(-t nat -C POSTROUTING -o "$LAN_IFACE" -d "$LAN_CIDR" -j MASQUERADE)
  if ipt_check_add "${R3[@]}"; then
    ok "  MASQUERADE (-> ${LAN_IFACE}, dst: $LAN_CIDR) eklendi"
  else
    ok "  MASQUERADE (-> ${LAN_IFACE}, dst: $LAN_CIDR) zaten mevcut"
  fi
else
  warn "  MASQUERADE atlanıyor (--masquerade no)"
  warn "  LAN routerinizde/switch'inizde '10.8.0.0/24 via 10.77.3.3' route olmali!"
fi

# ===========================================================
# 4. Kaydet (opsiyonel)
# ===========================================================
info "[4/4] Kayit..."

if [[ "${SAVE,,}" == "yes" ]]; then

  # iptables kurallari kaydet
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    ok "  netfilter-persistent ile kaydedildi"
  elif command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "  /etc/iptables/rules.v4 guncellendi"
  else
    # iptables-persistent yoksa if-up.d hook ile kalici yap
    warn "  iptables-persistent bulunamadi; if-up.d hook yaziliyor"
    warn "  Daha guvenilir kalicilik icin: apt install iptables-persistent"
    cat > "$IPTABLES_HOOK" <<HOOK
#!/bin/sh
# vpn-gw-side: iptables kurallari (otomatik olusturuldu)
[ "\$IFACE" = "$LAN_IFACE" ] || [ "\$IFACE" = "$VPN_TUN" ] || exit 0
iptables -C FORWARD -i $VPN_TUN -o $LAN_IFACE -d $LAN_CIDR -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i $VPN_TUN -o $LAN_IFACE -d $LAN_CIDR -j ACCEPT
iptables -C FORWARD -i $LAN_IFACE -o $VPN_TUN -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i $LAN_IFACE -o $VPN_TUN -m state --state RELATED,ESTABLISHED -j ACCEPT
HOOK
    if [[ "${MASQUERADE,,}" == "yes" ]]; then
      cat >> "$IPTABLES_HOOK" <<HOOK
iptables -t nat -C POSTROUTING -o $LAN_IFACE -d $LAN_CIDR -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o $LAN_IFACE -d $LAN_CIDR -j MASQUERADE
HOOK
    fi
    chmod +x "$IPTABLES_HOOK"
    ok "  if-up.d hook yazildi: $IPTABLES_HOOK"
  fi
else
  warn "  --save yes ile iptables kurallari kalici yapilabilir"
  warn "  Simdilik sadece bu oturumda gecerli"
fi

# ===========================================================
# OZET
# ===========================================================
echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${GREEN}[TAMAM] tin-gateway tarafi tamamlandi.${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""
echo -e "${BOLD}Dogrulama komutlari (bu makinede):${NC}"
echo ""
echo "  # ip_forward aktif mi?"
echo "  cat /proc/sys/net/ipv4/ip_forward   # 1 olmali"
echo ""
echo "  # FORWARD kurallari mevcut mu?"
echo "  iptables -L FORWARD -n --line-numbers | grep -E '${VPN_TUN}|${LAN_IFACE}'"
echo ""
if [[ "${MASQUERADE,,}" == "yes" ]]; then
  echo "  # MASQUERADE kurali mevcut mu?"
  echo "  iptables -t nat -L POSTROUTING -n --line-numbers | grep MASQUERADE"
  echo ""
fi
echo -e "${BOLD}Test (VPN clientlarindan):${NC}"
echo ""
echo "  ping -c3 $TUN_IP             # VPN client -> tin-gateway tun"
echo "  ping -c3 ${LAN_CIDR%/*}   # VPN client -> LAN network adresi"
echo "  # LAN'daki herhangi bir hostin IP'sini ping'le:"
echo "  # ping -c3 10.77.x.x"
echo ""
echo -e "${BOLD}tin (VPN server) tarafinda da script calismis olmali:${NC}"
echo "  reach-gateway.sh --gateway-tun-ip $TUN_IP --lan $LAN_CIDR --gateway-cn <CN> --save yes"
echo "  sudo systemctl restart openvpn-server@server   # tin'de"
echo ""
