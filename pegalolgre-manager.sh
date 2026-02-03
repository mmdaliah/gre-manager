#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ========= INPUT FIX =========
# Always read from keyboard even when piped (curl | bash)
read_tty() { read -r "$@" < /dev/tty; }

# ========= REQUIRE ROOT =========
if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run as root (sudo)."
  exit 1
fi

DB="/etc/gre-tunnels.db"
mkdir -p /etc
touch "$DB"

echo "===================================="
echo " GRE Manager (Safe, Interactive)"
echo "===================================="

# ========= HELPERS =========
next_gre_id() {
  local i=1
  while ip link show "gre$i" &>/dev/null; do i=$((i+1)); done
  echo "$i"
}

next_subnet_base() {
  local used
  used=$(awk '{print $6}' "$DB" | sort -n | tail -1)
  [[ -z "$used" ]] && echo 0 || echo $((used + 4))
}

next_key() {
  local used
  used=$(awk '{print $7}' "$DB" | sort -n | tail -1)
  [[ -z "$used" ]] && echo 10 || echo $((used + 1))
}

list_tunnels() {
  echo
  echo "Existing GRE tunnels (from DB):"
  echo "-----------------------------------------------------------------------"
  printf "%-6s %-15s %-15s %-15s %-15s\n" "IFACE" "LOCAL_PUB" "REMOTE_PUB" "LOCAL_TUN" "REMOTE_TUN"
  echo "-----------------------------------------------------------------------"
  while read -r iface lp rp lt rt base key; do
    printf "%-6s %-15s %-15s %-15s %-15s\n" "$iface" "$lp" "$rp" "$lt" "$rt"
  done < "$DB"
  echo
}

# ========= SAFE AUTO-CLEANUP =========
# Deletes ONLY GREs that match BOTH local+remote public IPs
cleanup_gre_safe() {
  local LOCAL_IP="$1"
  local REMOTE_IP="$2"

  echo "🔍 Checking GRE conflicts for local=$LOCAL_IP remote=$REMOTE_IP"

  mapfile -t MATCH < <(
    ip -d tunnel show | awk -v l="$LOCAL_IP" -v r="$REMOTE_IP" '
      $2=="gre/ip" && $0~("local "l) && $0~("remote "r) {
        sub(":", "", $1); print $1
      }'
  )

  if (( ${#MATCH[@]} == 0 )); then
    echo "✅ No conflicting GRE found"
    return
  fi

  echo "⚠️ Found ${#MATCH[@]} conflicting GRE(s). Cleaning safely:"
  for g in "${MATCH[@]}"; do
    echo "   ➜ deleting $g"
    ip tunnel del "$g"
  done
}

delete_tunnel() {
  list_tunnels
  read_tty -p "Enter GRE interface to delete (e.g. gre2): " IFACE
  ip tunnel del "$IFACE" 2>/dev/null || true
  grep -v "^$IFACE " "$DB" > /tmp/gre.db && mv /tmp/gre.db "$DB"
  echo "✅ $IFACE removed"
}

create_tunnel() {
  read_tty -p "Enter IRAN public IP: " IRAN_IP
  read_tty -p "Enter KHAREJ public IP: " KHAREJ_IP

  if [[ "$IRAN_IP" == "$KHAREJ_IP" ]]; then
    echo "❌ Local and Remote public IPs cannot be the same"
    exit 1
  fi

  echo
  echo "This server is:"
  echo "1) Iran"
  echo "2) Kharej"
  read_tty -p "Choice [1-2]: " ROLE
  [[ "$ROLE" != "1" && "$ROLE" != "2" ]] && { echo "Invalid choice"; exit 1; }

  GRE_ID=$(next_gre_id)
  BASE=$(next_subnet_base)
  KEY=$(next_key)
  IFACE="gre$GRE_ID"

  IRAN_TUN="10.77.122.$((BASE + 1))"
  KHAREJ_TUN="10.77.122.$((BASE + 2))"

  if [[ "$ROLE" == "1" ]]; then
    LOCAL_PUB="$IRAN_IP"
    REMOTE_PUB="$KHAREJ_IP"
    LOCAL_TUN="$IRAN_TUN"
    REMOTE_TUN="$KHAREJ_TUN"
    SIDE="IRAN"
  else
    LOCAL_PUB="$KHAREJ_IP"
    REMOTE_PUB="$IRAN_IP"
    LOCAL_TUN="$KHAREJ_TUN"
    REMOTE_TUN="$IRAN_TUN"
    SIDE="KHAREJ"
  fi

  # Guard: tunnel IP already used?
  if ip addr | grep -q "$LOCAL_TUN/30"; then
    echo "❌ Tunnel IP already in use: $LOCAL_TUN"
    exit 1
  fi

  echo
  echo "Configuring $SIDE server"
  echo "Interface : $IFACE"
  echo "Local Pub : $LOCAL_PUB"
  echo "Remote Pub: $REMOTE_PUB"
  echo "Local Tun : $LOCAL_TUN"
  echo "Remote Tun: $REMOTE_TUN"
  echo "GRE Key   : $KEY"
  echo

  modprobe ip_gre

  # ✅ SAFE auto-cleanup (ONLY same local+remote)
  cleanup_gre_safe "$LOCAL_PUB" "$REMOTE_PUB"

  ip tunnel add "$IFACE" mode gre \
    local "$LOCAL_PUB" \
    remote "$REMOTE_PUB" \
    key "$KEY" ttl 255

  ip link set "$IFACE" mtu 1476
  ip addr flush dev "$IFACE"
  ip addr add "$LOCAL_TUN/30" dev "$IFACE"
  ip link set "$IFACE" up

  # Firewall (idempotent)
  iptables -C INPUT  -p gre -j ACCEPT 2>/dev/null || iptables -I INPUT  -p gre -j ACCEPT
  iptables -C OUTPUT -p gre -j ACCEPT 2>/dev/null || iptables -I OUTPUT -p gre -j ACCEPT

  # rp_filter guards (interface-specific)
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
  sysctl -w "net.ipv4.conf.$IFACE.rp_filter=0" >/dev/null

  echo "$IFACE $LOCAL_PUB $REMOTE_PUB $LOCAL_TUN $REMOTE_TUN $BASE $KEY" >> "$DB"

  echo
  echo "✅ GRE tunnel created successfully"
  echo "👉 Test with: ping $REMOTE_TUN"
}

# ========= MENU =========
while true; do
  echo
  echo "================ GRE Tunnel Manager ================"
  echo "1) Create new GRE tunnel"
  echo "2) List existing tunnels"
  echo "3) Delete a tunnel"
  echo "4) Exit"
  echo "===================================================="
  read_tty -p "Select option [1-4]: " OPT

  case "$OPT" in
    1) create_tunnel ;;
    2) list_tunnels ;;
    3) delete_tunnel ;;
    4) exit 0 ;;
    *) echo "Invalid option" ;;
  esac
done
