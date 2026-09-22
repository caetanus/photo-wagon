# Waydroid on the Hetzner test VPN — no root needed

Goal: the Android side of the sync reaches the desktop over the INTERNET, from a foreign
network behind a NAT (Hetzner's masquerade), instead of the waydroid0 bridge — the 4G
scenario on the desk. See `hetzner-only-nat-testing` in the notes: the VPS is a NAT test
rig, nothing else.

Pieces:
- Hetzner: `wg-quick@wg0` (10.66.0.1/24, udp/51820, nft table `wgnat` masquerades
  10.66.0.0/24 out of eth0). Peer keys live in `~/.config/photowagon-rig/`.
- The container has no NAT to the internet of its own, so the tunnel's endpoint is the
  HOST and `udpfwd.py` relays it: `python3 udpfwd.py 192.168.240.1 51820 62.238.38.245 51820`.
- Inside Android: the official WireGuard app (userspace wg-go, VpnService — no root),
  tunnel `pwrig`: Address 10.66.0.10/24, DNS 1.1.1.1, Endpoint 192.168.240.1:51820,
  AllowedIPs 0.0.0.0/0, keepalive 25. Import the .conf from /sdcard/Download through the
  app's "+" → "Import from file" (uiautomator sees this app; `input tap` works), turn the
  switch on, accept the VPN dialog. Check: `adb shell curl https://ifconfig.me` → the
  Hetzner address; `sudo wg show wg0` on hetzner shows the handshake.

With AllowedIPs 0.0.0.0/0 the bridge shortcut to the desktop is closed by the VPN itself.
`../waydroid-wg.sh` is the root-only variant (wg interface moved into the container's
netns); not needed with the app.

## The NAT must be honest

Hetzner's default INPUT policy accepts unsolicited UDP. That makes it a NAT no real network
has: a peer's hole-punch packets arriving before ours create conntrack entries that book the
very tuple our outbound needs, masquerade then re-maps our source port, and the punch fails
even though both sides advertised the right addresses (2026-09-21 tcpdump). Run
`sudo sh hetzner-natfilter.sh` on the box once: it drops new inbound UDP on eth0 except
WireGuard, which is what a consumer router or a CGNAT does. To watch a punch:
`sudo tcpdump -ni eth0 'udp and host <desktop public ip> and not port 51820'` plus the same
on `wg0` for the tunnel side.
