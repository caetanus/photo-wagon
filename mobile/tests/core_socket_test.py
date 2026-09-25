# Protocol test for the phone core socket (docs/phone-core-service.md, stage 5).
# Run a host core first:  photo-wagon-mobile -service   (XDG_DATA_HOME short enough for sun_path)
# then:  python3 core_socket_test.py <dataDir>/core.sock <core pid>
# Case 7 needs PW_TEST_PAGE_DELAY==3000 on the core (a slow first page keeps requests outstanding).
import json, socket, sys, time
SOCK = sys.argv[1]
fails = []
def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what); (None if ok else fails.append(what))
import os
def conn(ui=None, hello=True):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(SOCK); s.settimeout(20)
    f = s.makefile("rb")
    if hello:
        s.sendall(json.dumps({"id": 0, "method": "core.hello", "params": {"uiInstance": ui or os.urandom(6).hex()}}).encode() + b"\n")
        m = frame(f); assert m and m.get("id") == 0, m
    return s, f
def frame(f):
    l = f.readline()
    return json.loads(l) if l else None
def until_id(f, i):
    while True:
        m = frame(f)
        if m is None or m.get("id") == i: return m
def closed(s, f, t=5):
    s.settimeout(t)
    try:
        while True:
            l = f.readline()
            if not l: return True
    except socket.timeout: return False
    except (ConnectionResetError, OSError): return True

print("1 first frame is core.state"); s, f = conn(); m = frame(f)
check(m.get("event") == "core.state" and "computer" in m["data"], "core.state first: %s" % str(m)[:80])
print("2 coalesced frames")
s.sendall(b'{"id":1,"method":"daemon.hello"}\n{"id":2,"method":"library.syncStatus"}\n')
a = until_id(f, 1); b = until_id(f, 2); check(a and "result" in a and b and "result" in b, "two answers from one write")
print("3 fragmented frame")
for ch in b'{"id":3,"method":"daemon.hello"}\n': s.send(bytes([ch])); time.sleep(0.002)
check("result" in (until_id(f, 3) or {}), "answer to a byte-by-byte frame")
print("4 invalid envelopes")
s.sendall(b'{"id":4,"method":3}\n{"id":5,"method":"x","params":[1]}\n')
check(until_id(f, 4).get("error", {}).get("code") == "invalid_request", "non-string method")
check(until_id(f, 5).get("error", {}).get("code") == "invalid_request", "array params")
print("5 duplicate outstanding id")
s.sendall(b'{"id":6,"method":"library.page","params":{"offset":0,"limit":60}}\n{"id":6,"method":"daemon.hello"}\n')
got = [until_id(f, 6), until_id(f, 6)]
check(any(g and g.get("error", {}).get("code") == "duplicate_id" for g in got) and any(g and "result" in g for g in got), "one duplicate_id, one answer")
print("6 unknown method"); s.sendall(b'{"id":7,"method":"no.such"}\n'); check("error" in until_id(f, 7), "error answer")
print("7 outstanding limit")
reqs = b'{"id":999,"method":"library.page","params":{"offset":0,"limit":60}}\n' + b''.join(b'{"id":%d,"method":"library.page","params":{"offset":60,"limit":1}}\n' % (1000 + i) for i in range(1100))
s.sendall(reqs); codes = {}
for i in range(1101):
    m = frame(f)
    while m and "event" in m: m = frame(f)
    c = m.get("error", {}).get("code", "ok") if m else "eof"; codes[c] = codes.get(c, 0) + 1
check(codes.get("too_many_requests", 0) > 0, "too_many_requests past 1024: %s" % codes)
s.close()
print("8 not JSON -> dropped"); s, f = conn(); frame(f); s.sendall(b'hello there\n'); check(closed(s, f), "connection closed")
print("9 no id -> dropped"); s, f = conn(); frame(f); s.sendall(b'{"method":"daemon.hello"}\n'); check(closed(s, f), "connection closed")
print("10 oversized frame -> dropped"); s, f = conn(); frame(f)
try:
    blk = b'x' * (1 << 20)
    for _ in range(40): s.sendall(blk)
except OSError: pass
check(closed(s, f), "connection closed after >32 MiB without a newline")
print("11 supersession"); s1, f1 = conn(); frame(f1); s2, f2 = conn(); frame(f2)
ev = frame(f1); check(ev and ev.get("event") == "session_superseded", "old session told: %s" % str(ev)[:60])
check(closed(s1, f1), "old session closed"); s2.sendall(b'{"id":1,"method":"daemon.hello"}\n'); check("result" in (until_id(f2, 1) or {}), "new session works")
print("12 output backpressure"); s2.sendall(b'{"id":2,"method":"library.page","params":{"offset":0,"limit":400}}\n'); until_id(f2, 2)
reqs = b''.join(b'{"id":%d,"method":"library.page","params":{"offset":1,"limit":400}}\n' % (100 + i) for i in range(1000))
s2.setblocking(True)
try: s2.sendall(reqs)
except OSError: pass
time.sleep(4)   # not reading: the core's unsent output grows past 64 MiB
check(closed(s2, f2, 30), "a client that does not read is dropped")
print("13 hello required"); s, f = conn(hello=False); s.sendall(b'{"id":1,"method":"daemon.hello"}\n')
check(until_id(f, 1).get("error", {}).get("code") == "hello_required", "hello_required"); s.close()
print("14 a superseded UI coming back is refused")
a, fa = conn("ui-A"); frame(fa); b, fb = conn("ui-B"); frame(fb)
check(frame(fa).get("event") == "session_superseded", "A superseded by B"); a.close()
a2 = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); a2.connect(SOCK); a2.settimeout(10); fa2 = a2.makefile("rb")
a2.sendall(b'{"id":0,"method":"core.hello","params":{"uiInstance":"ui-A"}}\n')
r = frame(fa2); check(r and r.get("error", {}).get("code") == "session_superseded", "A refused while B is live: %s" % str(r)[:70])
b.sendall(b'{"id":9,"method":"daemon.hello"}\n'); check("result" in (until_id(fb, 9) or {}), "B still works")
b.close(); fb.close(); time.sleep(0.5)
a3, fa3 = conn("ui-A"); m = frame(fa3); check(m and m.get("event") == "core.state", "A accepted once B is gone"); a3.close()
print("15 no leak per dropped connection")
pid = int(sys.argv[2])
def rss(): return int([l for l in open("/proc/%d/status" % pid) if l.startswith("VmRSS")][0].split()[1]) // 1024
time.sleep(1); r0 = rss()
for i in range(15):
    s, f = conn(); frame(f)
    try:
        for _ in range(33): s.sendall(b'x' * (1 << 20))
    except OSError: pass
    closed(s, f); s.close()
time.sleep(3); r1 = rss()
check(r1 - r0 < 150, "core RSS %d MiB -> %d MiB after 15 x 33 MiB dropped connections" % (r0, r1))
print("FAIL %d" % len(fails) if fails else "ALL PASS")
