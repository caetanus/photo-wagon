#!/usr/bin/env python3
"""Two headless photo-wagon instances: index on A, publish an album, fetch it on B over libp2p.

Run after `dub build`: tests/e2e.py <folder>. The folder must hold 9 images of which
exactly two are byte-identical (the dedupe check counts on it); a subfolder is fine."""
import json, os, socket, subprocess, sys, time, shutil

S = os.path.dirname(os.path.abspath(__file__))

DAEMON = os.path.join(S, "..", "photo-wagon")
WORK = os.path.join(S, "e2e-work")
os.makedirs(WORK, exist_ok=True)
PHOTOS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit("usage: e2e.py <dir with 9 images, two identical>")


class Node:
    def __init__(self, name):
        self.name = name
        self.dir = os.path.join(WORK, "node-" + name)
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        self.log = open(os.path.join(self.dir, "daemon.log"), "w")
        self.proc = subprocess.Popen([DAEMON, "--headless", "--data", self.dir, "--runtime", self.dir, "-v",
                                      "--p2p-listen", "/ip4/127.0.0.1/tcp/0"],
                                     stdout=self.log, stderr=subprocess.STDOUT)
        portfile = os.path.join(self.dir, "daemon.port")
        for _ in range(100):
            if os.path.exists(portfile):
                break
            time.sleep(0.1)
        else:
            raise SystemExit(f"{name}: no port file")
        port = int(open(portfile).read().strip())
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.buf = b""
        self.events = []
        self.next_id = 1

    def _readline(self, timeout=30):
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit(f"{self.name}: daemon closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, method, params=None, timeout=30):
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": rid, "method": method, "params": params or {}}) + "\n").encode())
        while True:
            msg = self._readline(timeout)
            if "event" in msg:
                self.events.append(msg)
                continue
            assert msg.get("id") == rid, msg
            if "error" in msg:
                raise RuntimeError(f"{self.name}: {method} -> {msg['error']}")
            return msg["result"]

    def wait_event(self, name, pred=lambda d: True, timeout=60):
        for e in self.events:
            if e["event"] == name and pred(e["data"]):
                return e["data"]
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self._readline(timeout)
            if "event" in msg:
                self.events.append(msg)
                if msg["event"] == name and pred(msg["data"]):
                    return msg["data"]
        raise SystemExit(f"{self.name}: timed out waiting for {name}")

    def stop(self):
        try:
            self.call("daemon.shutdown")
        except Exception:
            pass
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            print(f"{self.name}: had to kill")
        self.log.close()


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        global failures
        failures += 1


failures = 0
a = Node("a")
hello = a.call("daemon.hello")
print("A hello:", json.dumps(hello))
check(hello["version"] and hello["peerId"], "hello has version and peerId")

rid = a.call("library.addRoot", {"path": PHOTOS})["id"]
done = a.wait_event("index.done", lambda d: d["rootId"] == rid)
print("A index.done:", done)
check(done["imported"] == 8 and done["skipped"] == 1, "8 imported, 1 duplicate skipped")
progress = [e for e in a.events if e["event"] == "index.progress"]
check(len(progress) >= 2, f"progress events arrived ({len(progress)})")

page = a.call("library.page", {"offset": 0, "limit": 5})
print("A page total:", page["total"], "first:", json.dumps(page["items"][0]))
check(page["total"] == 8 and len(page["items"]) == 5, "page total 8, 5 items")
first = page["items"][0]
thumb = first["thumbUrl"]
check(thumb.startswith("file://") and os.path.exists(thumb[7:]), "thumbnail exists on disk")
check(first["width"] > 0 and first["height"] > 0, "dimensions filled")

dates = a.call("library.dates")
check(dates["years"] and dates["years"][0]["count"] > 0, f"dates tree: {[(y['year'], y['count']) for y in dates['years']]}")
y = dates["years"][0]
m = y["months"][0]
filtered = a.call("library.page", {"year": y["year"], "month": m["month"], "limit": 100})
check(filtered["total"] == m["count"], f"month filter count matches ({filtered['total']})")

nb = a.call("photo.neighbours", {"id": first["id"]})
check(nb["prev"] is None and nb["next"] is not None, f"neighbours of newest: {nb}")
got = a.call("photo.get", {"id": nb["next"]})
check(got["id"] == nb["next"], "photo.get")

# places: none of the test images has GPS, so the user's word is the way in
a.call("photo.setPlace", {"ids": [first["id"], nb["next"]], "place": "sao paulo"})
places = a.call("places.list")["places"]
check(len(places) == 1 and places[0]["place"] == "São Paulo" and places[0]["country"] == "Brazil" and places[0]["count"] == 2,
      f"a typed city gets its proper name and country: {places}")
check(places[0]["cover"] and places[0]["cover"].startswith("file://"), "the place card has a cover")
check(a.call("library.page", {"place": "São Paulo", "country": "Brazil", "limit": 10})["total"] == 2, "page filtered by place")
sugg = a.call("places.suggest", {"q": "sao"})["places"]
check(sugg and sugg[0]["place"] == "São Paulo" and sugg[0]["own"], f"suggestions list the library's own place first: {sugg[:2]}")
a.call("photo.setPlace", {"ids": [first["id"]], "place": ""})
check(a.call("places.list")["places"][0]["count"] == 1, "clearing a place")

# rescan is incremental: nothing new
a.call("library.rescan")
done2 = a.wait_event("index.done", lambda d: d["rootId"] == rid and d is not done)
check(done2["imported"] == 0 and done2["skipped"] == 9, f"rescan skipped everything: {done2}")

try:
    a.call("nope.method")
    check(False, "unknown method errors")
except RuntimeError as e:
    check("unknown_method" in str(e), "unknown method errors")

# ---- p2p -------------------------------------------------------------------
b = Node("b")
status_a = a.call("p2p.status")
print("A p2p:", json.dumps(status_a))
addr = status_a["addrs"][0]
check("/p2p/" in addr, "A has a dialable address")
peer_a = b.call("p2p.connect", {"multiaddr": addr})["peerId"]
check(peer_a == status_a["peerId"], "B dialled A")
ev = a.wait_event("p2p.peer", lambda d: d["connected"])
print("A saw peer:", ev)
time.sleep(1.0)
status_b = b.call("p2p.status")
peers_b = [p for p in status_b["peers"] if p["connected"]]
check(peers_b and peers_b[0]["peerId"] == peer_a, f"B lists A as connected (agent={peers_b[0].get('agent') if peers_b else None})")
check(peers_b and peers_b[0].get("agent", "").startswith("photowagon/"), "identify exchanged agent version")

all_ids = [p["id"] for p in a.call("library.page", {"limit": 100})["items"]]
alb = a.call("album.create", {"name": "trip", "photoIds": all_ids})["id"]
manifest = a.call("album.publish", {"id": alb})["manifest"]
print("A manifest:", manifest)
check(len(manifest) == 64, "manifest hash")
albums_a = a.call("album.list")["albums"]
check(albums_a[0]["photos"] == 8 and albums_a[0]["manifest"] == manifest, "album.list on A")

remote = b.call("p2p.fetchAlbum", {"peerId": peer_a, "manifest": manifest})["albumId"]
fin = b.wait_event("p2p.fetch", lambda d: d["albumId"] == remote and d["done"] == d["total"])
print("B fetch:", fin)
check(fin["total"] == 8, "fetched 8 entries")
b.wait_event("library.changed")
bp = b.call("album.page", {"id": remote, "limit": 100})
check(bp["total"] == 8, "album.page on B has 8")
thumbs_ok = all(it["thumbUrl"] and os.path.exists(it["thumbUrl"][7:]) for it in bp["items"])
check(thumbs_ok, "all thumbnails present in B's store")
check(all(it["remote"] and it["path"] is None for it in bp["items"]), "B's photos are remote")
check(bp["items"][0]["hash"] == first["hash"], "same ordering/newest first")
albums_b = b.call("album.list")["albums"]
check(albums_b[0]["remote"] and albums_b[0]["originPeer"] == peer_a, "B album marked remote from A")

try:
    b.call("p2p.fetchAlbum", {"peerId": peer_a, "manifest": "0" * 64})
    check(False, "missing manifest errors")
except RuntimeError as e:
    check("not_found" in str(e), "missing manifest -> not_found")

a.stop()
b.stop()
check(a.proc.returncode == 0 and b.proc.returncode == 0, f"clean exits ({a.proc.returncode}, {b.proc.returncode})")
check(not os.path.exists(os.path.join(a.dir, "daemon.port")), "port file removed")
print(f"\n{failures} failures")
sys.exit(1 if failures else 0)
