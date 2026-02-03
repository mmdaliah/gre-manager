#!/bin/bash
set -e

DB="/etc/gre-tunnels.db"

mkdir -p /etc
touch "$DB"

function next_gre_id() {
    local i=1
    while ip link show gre$i &>/dev/null; do
        i=$((i+1))
    done
    echo "$i"
}

function next_subnet_base() {
    local used
    used=$(awk '{print $6}' "$DB" | sort -n | tail -1)
    [[ -z "$used" ]] && echo 0 || echo $((used + 4))
}

function next_key() {
    local used
    used=$(awk '{print $7}' "$DB" | sort -n | tail -1)
    [[ -z "$used" ]] && echo 10 || echo $((used + 1))
}

function list_tunnels() {
    echo
    echo "Existing GRE tunnels:"
    echo "------------------------------------------------------------"
    printf "%-6s %-15s %-15s %-15s %-15s\n" "IFACE" "LOCAL_PUBLIC" "REMOTE_PUBLIC" "LOCAL_TUN" "REMOTE_TUN"
    echo "------------------------------------------------------------"
    while read -r iface lp rp lt rt base key; do
        printf "%-6s %-15s %-15s %-15s %-15s\n" "$iface" "$lp" "$rp" "$lt" "$rt"
    done < "$DB"
    echo
}

function delete_tunnel() {
    list_tunnels
    read -p "Enter GRE interface to delete (e.g. gre2): " IFACE
    sudo ip tunnel del "$IFACE" 2>/dev/null || true
    grep -v "^$IFACE " "$DB" > /tmp/gre.db && mv /tmp/gre.db "$DB"
    echo "✅ $IFACE removed"
}

function create_tunnel() {
    read -p "Enter IRAN public IP: " IRAN_IP
    read -p "Enter KHAREJ public IP: " KHAREJ_IP

    echo
    echo "This server is:"
    echo "1) Iran"
    echo "2) Kharej"
    read -p "Choice [1-2]: " ROLE

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

    echo
    echo "Configuring $SIDE server"
    echo "Interface : $IFACE"
    echo "Local Pub : $LOCAL_PUB"
    echo "Remote Pub: $REMOTE_PUB"
    echo "Local Tun : $LOCAL_TUN"
    echo "Remote Tun: $REMOTE_TUN"
    echo "GRE Key   : $KEY"
    echo

    sudo modprobe ip_gre

    sudo ip tunnel del "$IFACE" 2>/dev/null || true

    sudo ip tunnel add "$IFACE" mode gre \
        local "$LOCAL_PUB" \
        remote "$REMOTE_PUB" \
        key "$KEY" ttl 255

    sudo ip link set "$IFACE" mtu 1476
    sudo ip addr flush dev "$IFACE"
    sudo ip addr add "$LOCAL_TUN/30" dev "$IFACE"
    sudo ip link set "$IFACE" up

    sudo iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p gre -j ACCEPT
    sudo iptables -C OUTPUT -p gre -j ACCEPT 2>/dev/null || sudo iptables -I OUTPUT -p gre -j ACCEPT

    echo "$IFACE $LOCAL_PUB $REMOTE_PUB $LOCAL_TUN $REMOTE_TUN $BASE $KEY" >> "$DB"

    echo
    echo "✅ Tunnel created successfully"
    echo "👉 Test with: ping $REMOTE_TUN"
}

while true; do
    echo
    echo "================ GRE Tunnel Manager ================"
    echo "1) Create new GRE tunnel"
    echo "2) List existing tunnels"
    echo "3) Delete a tunnel"
    echo "4) Exit"
    echo "===================================================="
    read -p "Select option [1-4]: " OPT

    case "$OPT" in
        1) create_tunnel ;;
        2) list_tunnels ;;
        3) delete_tunnel ;;
        4) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
done
