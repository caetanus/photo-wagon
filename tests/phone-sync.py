#!/usr/bin/env python3
"""The phone's automatic sync against a headless core, on the desktop build of the
phone client (offscreen): photos go to the computer by themselves, the computer is
asked by hash before any bytes move, and a kill in the middle loses nothing.

usage: tests/phone-sync.py <dir with a few images> [<dir with lena.jpg and friends, for faces>]
"""
import json, os, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
CORE = os.path.join(ROOT, "photo-wagon")
PHONE = os.path.join(ROOT, "mobile", "photo-wagon-mobile")
PHOTOS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)

fails = 0
def check(cond, what):
    global fails
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails += 1

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def call(port, method, params=None):
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    s.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    r = json.loads(buf.split(b"\n")[0])
    if r.get("error"):
        raise RuntimeError(r["error"])
    return r.get("result")

tmp = tempfile.mkdtemp(prefix="pw-sync-")
core_dir = os.path.join(tmp, "core"); os.makedirs(core_dir)
phone_data = os.path.join(tmp, "phone-data"); phone_cache = os.path.join(tmp, "phone-cache")
port = free_port()
core = subprocess.Popen([CORE, "--headless", "--data", core_dir, "--runtime", core_dir, "--port", str(port), "--no-p2p"],
                        stdout=open(os.path.join(tmp, "core.log"), "w"), stderr=subprocess.STDOUT)
for _ in range(100):
    try:
        call(port, "daemon.hello"); break
    except Exception:
        time.sleep(0.1)
else:
    sys.exit("core did not start")

env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
           PW_PHONE_ROOTS=PHOTOS, PW_ENDPOINT="127.0.0.1:%d" % port,
           XDG_DATA_HOME=os.path.join(tmp, "xdg-data"), XDG_CACHE_HOME=os.path.join(tmp, "xdg-cache"),
           XDG_CONFIG_HOME=os.path.join(tmp, "xdg-config"))

def phone(seconds, shot, extra=None):
    e = dict(env, PW_SHOT=os.path.join(tmp, shot))
    if extra: e.update(extra)
    p = subprocess.Popen([PHONE], env=e, stdout=open(os.path.join(tmp, shot + ".log"), "w"), stderr=subprocess.STDOUT)
    return p

def phone_log(shot):
    return open(os.path.join(tmp, shot + ".log")).read()

def index():
    for base, _, files in os.walk(os.path.join(tmp, "xdg-data")):
        if "phone-index.json" in files:
            return json.load(open(os.path.join(base, "phone-index.json")))
    return None

n_images = len([f for f in os.listdir(PHOTOS) if f.lower().endswith((".jpg", ".jpeg", ".png"))])
sub = os.path.join(PHOTOS, "sub")
if os.path.isdir(sub):
    n_images += len([f for f in os.listdir(sub) if f.lower().endswith((".jpg", ".jpeg", ".png"))])

# 1. auto sync off: nothing moves by itself
p = phone(8, "off.png"); time.sleep(8); p.terminate(); p.wait()
check(call(port, "library.stats")["total"] == 0, "sync off: nothing sent by itself")

# 2. PW_SHOT_SEND=1 presses "Sync": everything goes, once
p = phone(20, "on.png", {"PW_SHOT_SEND": "1"})
for _ in range(60):
    time.sleep(0.5)
    if "sync: done" in phone_log("on.png"):
        break
p.terminate(); p.wait()
log = phone_log("on.png")
total = call(port, "library.stats")["total"]
check("sync: done" in log, "sync ran to the end: " + [l for l in log.splitlines() if "sync: done" in l][-1:][0].split("sync: ")[-1] if "sync: done" in log else "sync never finished")
check(total > 0 and total <= n_images, "computer indexed %d of %d files (identical ones deduped)" % (total, n_images))
idx = index()
check(idx is not None and all(ph["sent"] for ph in idx["photos"]), "every phone photo marked sent, hash saved: %s"
      % (idx is not None and all(ph.get("hash") for ph in idx["photos"])))

# 3. the setting survives: a new launch with a new computer asks by hash and sends nothing twice
before = [l for l in open(os.path.join(tmp, "core.log")).read().splitlines() if "import:" in l]
p = phone(10, "again.png"); time.sleep(10); p.terminate(); p.wait()
after = [l for l in open(os.path.join(tmp, "core.log")).read().splitlines() if "import:" in l]
check(len(after) == len(before), "second launch: nothing re-sent (%d imports before, %d after)" % (len(before), len(after)))

# 4. a kill in the middle: reset the phone index to unsent, start, kill after the first send, restart → the rest goes
idx = index()
for ph in idx["photos"]:
    ph["sent"] = False
for base, _, files in os.walk(os.path.join(tmp, "xdg-data")):
    if "phone-index.json" in files:
        json.dump(idx, open(os.path.join(base, "phone-index.json"), "w"))
p = phone(30, "kill.png")
for _ in range(100):
    time.sleep(0.1)
    i2 = index()
    if i2 and any(ph["sent"] for ph in i2["photos"]) and not all(ph["sent"] for ph in i2["photos"]):
        break
os.kill(p.pid, signal.SIGKILL); p.wait()
partial = index()
done_before = sum(1 for ph in partial["photos"] if ph["sent"])
check(0 < done_before < len(partial["photos"]), "killed mid-sync with %d of %d sent" % (done_before, len(partial["photos"])))
p = phone(20, "resume.png")
for _ in range(60):
    time.sleep(0.5)
    i3 = index()
    if i3 and all(ph["sent"] for ph in i3["photos"]):
        break
p.terminate(); p.wait()
i3 = index()
check(all(ph["sent"] for ph in i3["photos"]), "after the restart the rest went (%d of %d)" % (sum(1 for ph in i3["photos"] if ph["sent"]), len(i3["photos"])))
after2 = [l for l in open(os.path.join(tmp, "core.log")).read().splitlines() if "import:" in l]
check(len(after2) == len(before), "and the computer, asked by hash, stored nothing twice")
status = json.load(open(os.path.join(tmp, "xdg-data", "PhotoWagon", "photo-wagon-mobile", "settings", "sync-status")))
check(status["enabled"] and not status["active"] and status["pending"] == 0, "sync-status file for the notification: " + json.dumps(status))

core.terminate(); core.wait()

# 5. the same over libp2p: a core with its node on, the pairing code carrying its
#    addresses, the phone dialing them instead of the TCP listener
core2_dir = os.path.join(tmp, "core2"); os.makedirs(core2_dir)
port2 = free_port()
core2 = subprocess.Popen([CORE, "--headless", "--data", core2_dir, "--runtime", core2_dir, "--port", str(port2),
                          "--models", os.path.join(ROOT, "models")],
                         stdout=open(os.path.join(tmp, "core2.log"), "w"), stderr=subprocess.STDOUT)
for _ in range(100):
    try:
        call(port2, "daemon.hello"); break
    except Exception:
        time.sleep(0.1)
pairing = call(port2, "phone.pairing", {"enable": True})
check(len(pairing.get("p2p", [])) > 0 and "#/ip4/" in pairing["code"], "pairing code carries libp2p addresses: " + pairing["code"][-60:])
shutil.rmtree(os.path.join(tmp, "xdg-data"), ignore_errors=True)   # a fresh phone
p = phone(25, "p2p.png", {"PW_ENDPOINT": pairing["code"], "PW_SHOT_SEND": "1"})
for _ in range(80):
    time.sleep(0.5)
    if "sync: done" in phone_log("p2p.png"):
        break
p.terminate(); p.wait()
log = phone_log("p2p.png")
check("p2p: connected to" in log, "phone connected over libp2p: " + ([l for l in log.splitlines() if "p2p: connected" in l] or ["no"])[0].split("p2p: ")[-1])
check("sync: done" in log, "sync over libp2p ran to the end")
total2 = call(port2, "library.stats")["total"]
check(total2 > 0, "computer received the photos over libp2p (%d)" % total2)
check("ipc/p2p" in open(os.path.join(tmp, "core2.log")).read(), "the core saw the phone on /photowagon/ipc/1.0.0")
# 6. faces: the computer finds them in what the phone sent; the phone shows them on
#    its own copy (matched by hash) and can name them; with a face folder if given
faces_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
if faces_dir:
    shutil.rmtree(os.path.join(tmp, "xdg-data"), ignore_errors=True)
    e = {"PW_ENDPOINT": pairing["code"], "PW_SHOT_SEND": "1", "PW_PHONE_ROOTS": faces_dir}
    p = phone(25, "faces-sync.png", e)
    for _ in range(80):
        time.sleep(0.5)
        if "sync: done" in phone_log("faces-sync.png"):
            break
    p.terminate(); p.wait()
    people = []
    for _ in range(120):
        time.sleep(1)
        people = call(port2, "people.list").get("people", [])
        if people:
            break
    check(len(people) > 0, "computer found people in the phone's photos: %d" % len(people))
    idx = index()
    lena = next((ph["id"] for ph in idx["photos"] if ph["path"].endswith("/lena.jpg")), None)
    check(lena is not None and idx is not None, "the phone's own copy of lena.jpg is photo %s" % lena)
    e2 = dict(e); e2.pop("PW_SHOT_SEND"); e2["PW_SHOT_OPEN"] = str(lena or 1)
    p = phone(20, "faces-open.png", e2)
    for _ in range(60):
        time.sleep(0.5)
        if "faces: " in phone_log("faces-open.png"):
            break
    p.terminate(); p.wait()
    line = ([l for l in phone_log("faces-open.png").splitlines() if "faces: " in l] or ["faces: none"])[0]
    check("faces: 1 for photo %s" % lena in line, "the phone got the computer's faces for its own photo: " + line.split("faces: ")[-1])
    lena_hash = next((ph.get("hash") for ph in idx["photos"] if ph["id"] == lena), None)
    try:
        cid = call(port2, "library.byHash", {"sha256": lena_hash})["id"]
        cfaces = call(port2, "photo.faces", {"id": cid})["faces"]
        check(len(cfaces) == 1, "the computer has lena.jpg (id %d) with %d face" % (cid, len(cfaces)))
        call(port2, "face.setPerson", {"faceId": cfaces[0]["id"], "name": "Lena"})
        people = call(port2, "people.list")["people"]
        check(any(pp.get("name") == "Lena" for pp in people), "a name given goes into the computer's people (the phone sends face.setPerson the same way)")
    except Exception as ex:
        check(False, "naming through the computer: %s (hash %s)" % (ex, lena_hash))

core2.terminate(); core2.wait()
print("\n%d failures  (%s)" % (fails, tmp))
sys.exit(1 if fails else 0)
