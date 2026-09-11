#!/usr/bin/env python3
"""Face recognition against a headless photo-wagon.

tests/faces.py <folder>   — the folder must hold lena.jpg, lena-flipped.jpg,
lena-small.jpg, messi5.jpg, messi-rot.jpg (EXIF orientation 6) and both.jpg
(lena + messi side by side): three photos of one person, two of another, one
with both. Faces must be at least 48 px wide (the clustering gate): the OpenCV
sample messi5.jpg has to be scaled 2x first.
"""
import json, os, socket, subprocess, sys, time, shutil

S = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(S, "..", "photo-wagon")
WORK = os.path.join(S, "e2e-work", "faces")
PHOTOS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit("usage: faces.py <folder>")

shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
log = open(os.path.join(WORK, "core.log"), "w")
proc = subprocess.Popen([BIN, "--headless", "--exit-with-parent", "--data", WORK, "--runtime", WORK, "--no-p2p", "-v",
                         "--models", os.path.join(S, "..", "models")], stdout=log, stderr=subprocess.STDOUT)
portfile = os.path.join(WORK, "daemon.port")
for _ in range(100):
    if os.path.exists(portfile):
        break
    time.sleep(0.1)
sock = socket.create_connection(("127.0.0.1", int(open(portfile).read())))
buf = b""
events = []
nid = 0


def readline(timeout=120):
    global buf
    sock.settimeout(timeout)
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise SystemExit("core closed the connection")
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return json.loads(line)


def call(method, params=None):
    global nid
    nid += 1
    sock.sendall((json.dumps({"id": nid, "method": method, "params": params or {}}) + "\n").encode())
    while True:
        m = readline()
        if "event" in m:
            events.append(m)
            continue
        if "error" in m:
            raise RuntimeError(f"{method}: {m['error']}")
        return m["result"]


def wait_event(name, pred=lambda d: True, timeout=180):
    for e in events:
        if e["event"] == name and pred(e["data"]):
            return e["data"]
    end = time.time() + timeout
    while time.time() < end:
        m = readline(timeout)
        if "event" in m:
            events.append(m)
            if m["event"] == name and pred(m["data"]):
                return m["data"]
    raise SystemExit(f"timed out waiting for {name}")


failures = 0


def check(cond, what):
    global failures
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures += 1


st = call("faces.status")
check(st["available"], "face models loaded")
call("library.addRoot", {"path": PHOTOS})
wait_event("index.done")
done = wait_event("faces.done")
print("faces.done:", done)
check(done["photos"] == 6, "6 photos scanned")
check(done["faces"] == 7, f"7 faces found ({done['faces']})")

people = call("people.list")["people"]
print("people:", [(p["id"], p["name"], p["faces"]) for p in people])
check(len(people) == 2, "two people")
lena = max(people, key=lambda p: p["faces"])
messi = min(people, key=lambda p: p["faces"])
check(lena["faces"] == 4 and messi["faces"] == 3, "lena has 4 faces, messi 3")
check(all(p["coverUrl"] and os.path.exists(p["coverUrl"][7:]) for p in people), "cover crops exist")

# photos of one person, via the page filter
page = call("library.page", {"personId": lena["id"], "limit": 10})
check(page["total"] == 4, f"page filtered by person: {page['total']}")
both = [it for it in call("library.page", {"limit": 10})["items"] if it["path"].endswith("both.jpg")][0]
faces = call("photo.faces", {"id": both["id"]})["faces"]
check(len(faces) == 2 and {f["personId"] for f in faces} == {lena["id"], messi["id"]}, "both.jpg has one face of each")
check(all(0 <= f["x"] < 1 and 0 < f["w"] <= 1 for f in faces), "boxes are fractions")

# naming, merging, reassigning
call("people.rename", {"id": lena["id"], "name": "Lena"})
wait_event("people.changed")
people = call("people.list")["people"]
check(any(p["name"] == "Lena" for p in people), "renamed")
lena_face = [f for f in faces if f["personId"] == lena["id"]][0]
r = call("face.setPerson", {"faceId": lena_face["id"], "name": "Someone Else"})
check(r["personId"] not in (lena["id"], messi["id"]), "face moved to a new named person")
people = call("people.list")["people"]
check(len(people) == 3 and any(p["name"] == "Someone Else" for p in people), "three people now")
call("people.merge", {"id": r["personId"], "into": lena["id"]})
people = call("people.list")["people"]
check(len(people) == 2 and max(people, key=lambda p: p["faces"])["faces"] == 4, "merged back")

# rescan is a no-op
call("faces.scan")
time.sleep(1)
st = call("faces.status")
check(st["scanned"] == 6 and st["total"] == 6, f"all scanned: {st}")

call("daemon.shutdown")
proc.wait(10)
print(f"\n{failures} failures")
sys.exit(1 if failures else 0)
