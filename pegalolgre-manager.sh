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
  used=$(awk '{print \$6}' "$DB" | sort -n | tail -1)
  [[ -z "$used" ]] && echo 0 || echo $((used + 4))
}

next_key() {
  local used
  used=$(awk '{print \$7}' "$DB" | sort -n | tail -1)
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
  local LOCAL_IP="\$1"
  local REMOTE_IP="\$2"

  echo "🔍 Checking GRE conflicts for local=$LOCAL_IP remote=$REMOTE_IP"

  mapfile -t MATCH < <(
    ip -d tunnel show | awk -v l="$LOCAL_IP" -v r="$REMOTE_IP" '
      \$2=="gre/ip" && \$0~("local "l) && \$0~("remote "r) {
        sub(":", "", \$1); print \$1
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
