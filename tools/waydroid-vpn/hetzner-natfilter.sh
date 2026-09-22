#!/bin/sh
# NAT rig: behave like a real NAT — drop UNSOLICITED inbound UDP on eth0 (except WireGuard).
# With INPUT accepting everything, a peer's hole-punch packets arriving before ours create a
# conntrack entry that occupies the tuple our own outbound needs, so masquerade re-maps our
# source port and the punch fails (the 2026-09-21 tcpdump: desktop → :46751 arrived first,
# phone's went out as :23245). Unconfirmed entries of dropped packets are discarded.
set -e
nft add table inet pwfilter 2>/dev/null || true
nft 'add chain inet pwfilter input { type filter hook input priority -10; policy accept; }' 2>/dev/null || true
nft flush chain inet pwfilter input
nft add rule inet pwfilter input iifname eth0 udp dport 51820 accept
nft add rule inet pwfilter input iifname eth0 meta l4proto udp ct state new drop
nft list chain inet pwfilter input | grep -E 'udp'
conntrack -F 2>/dev/null && echo "conntrack flushed" || echo "(no conntrack tool; entries expire on their own)"
