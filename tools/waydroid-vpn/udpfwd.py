# Plain UDP forwarder: whatever arrives on LISTEN goes to TARGET; replies go back to the last
# sender. One client (the Waydroid WireGuard tunnel) — the container has no NAT to the
# internet on its own, so its WireGuard endpoint is the host, and the host relays.
import socket, select, sys
listen, target = (sys.argv[1], int(sys.argv[2])), (sys.argv[3], int(sys.argv[4]))
a = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); a.bind(listen)
b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); b.connect(target)
client = None
while True:
    r, _, _ = select.select([a, b], [], [])
    for s in r:
        if s is a:
            data, client = a.recvfrom(65535); b.send(data)
        else:
            data = b.recv(65535)
            if client: a.sendto(data, client)
