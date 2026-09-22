#!/bin/sh
# Put the Waydroid container on the Hetzner WireGuard test VPN, so the Android side reaches the
# desktop over the INTERNET (egress = Hetzner, behind its endpoint-independent NAT) instead of the
# waydroid0 bridge — a stand-in for "the phone on another network", no phone in hand.
#
#   sudo tools/waydroid-wg.sh up      # wg interface into the container netns, default route via VPN,
#                                     # bridge traffic to the host limited to DNS/DHCP
#   sudo tools/waydroid-wg.sh down    # undo
#
# The WireGuard interface is CREATED in the host netns (so its UDP socket, and the traffic to the
# server, live on the host) and MOVED into the container — WireGuard's namespace trick. Keys:
# ~/.config/photowagon-rig/{droid.key,server.pub}; server = hetzner wg0 (10.66.0.1, udp/51820), see
# the "Hetzner = NAT-test rig" notes. Needs root on the host; Waydroid session must be running.
set -e
RIG=${RIG:-/home/caetano/.config/photowagon-rig}
SERVER=${SERVER:-62.238.38.245:51820}
IF=wgdroid
ADDR=10.66.0.10/24
PID=$(pgrep -x zygote64 | head -1)   # any process inside the container: its netns is the container's
[ -n "$PID" ] || { echo "waydroid container not running (no zygote64)"; exit 1; }
NS="nsenter -t $PID -n"
case "${1:-up}" in
up)
    ip link show $IF >/dev/null 2>&1 && { echo "$IF already exists on the host; run down first"; exit 1; }
    ip link add $IF type wireguard
    wg set $IF private-key "$RIG/droid.key" peer "$(cat "$RIG/server.pub")" endpoint "$SERVER" \
        allowed-ips 0.0.0.0/0 persistent-keepalive 25
    ip link set $IF netns /proc/$PID/ns/net
    $NS ip addr add $ADDR dev $IF
    $NS ip link set $IF up
    # everything via the VPN; the bridge stays only as a link route (DNS/DHCP to the host's dnsmasq)
    $NS ip route replace default dev $IF
    # ...and on the host, refuse the rest from the bridge: no LAN shortcut to the desktop, no
    # internet via the bridge. (Waydroid's own table accepts 53/67 first.)
    nft add table inet pwrig
    nft 'add chain inet pwrig input { type filter hook input priority 10; }'
    nft add rule inet pwrig input iifname waydroid0 udp dport '{ 53, 67 }' accept
    nft add rule inet pwrig input iifname waydroid0 tcp dport 53 accept
    nft add rule inet pwrig input iifname waydroid0 tcp dport 5555 accept   # adb from the host
    nft add rule inet pwrig input iifname waydroid0 drop
    nft 'add chain inet pwrig forward { type filter hook forward priority 10; }'
    nft add rule inet pwrig forward iifname waydroid0 drop
    sleep 2
    echo "--- container:"; $NS ip -4 addr show $IF | grep inet; $NS ip -4 route show
    echo "--- wg:"; $NS wg show $IF | sed 's/private key.*/private key: (hidden)/'
    echo "--- egress seen by the internet:"; $NS curl -s --max-time 8 ifconfig.me || echo "(no answer yet)"
    ;;
down)
    $NS ip link del $IF 2>/dev/null || ip link del $IF 2>/dev/null || true
    $NS ip route replace default via 192.168.240.1 dev eth0 2>/dev/null || true
    nft delete table inet pwrig 2>/dev/null || true
    echo "vpn off; container back on the bridge"
    ;;
*) echo "usage: $0 up|down"; exit 2 ;;
esac
