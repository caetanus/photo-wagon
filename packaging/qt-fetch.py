#!/usr/bin/env python3
"""Fetches a Qt 6 kit from qt.io's online repository, verifying every archive's sha256.

    qt-fetch.py <version> <kit> <dest> [addon ...]

    kit: linux_gcc_64 (desktop) or android_arm64_v8a / android_x86_64
    dest: the kit lands in <dest>/<version>/<gcc_64|android_arm64_v8a|...>

The same repository walk as DSide's tools/linux/get-qt.sh (Updates.xml → archives → the
published .sha256), for the Android kits too, which that script does not cover. Needs py7zr.
"""
import hashlib
import os
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

import py7zr

BASE = "https://download.qt.io/online/qtsdkrepository"


def repo_for(version, kit):
    v = version.replace(".", "")
    if kit == "linux_gcc_64":
        return f"{BASE}/linux_x64/desktop/qt6_{v}/qt6_{v}", "gcc_64"
    if kit.startswith("android_"):
        arch = kit[len("android_"):]
        return f"{BASE}/all_os/android/qt6_{v}/qt6_{v}_{arch}", kit
    sys.exit(f"qt-fetch: unknown kit {kit}")


def get(url):
    with urllib.request.urlopen(url) as r:
        return r.read()


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    version, kit, dest, addons = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    repo, kitdir = repo_for(version, kit)
    prefix = os.path.join(dest, version, kitdir)
    os.makedirs(prefix, exist_ok=True)
    v = version.replace(".", "")
    want = [f"qt.qt6.{v}.{kit}"] + [f"qt.qt6.{v}.addons.{a}.{kit}" for a in addons]
    root = ET.fromstring(get(f"{repo}/Updates.xml"))
    found = {}
    for p in root.iter("PackageUpdate"):
        name = p.findtext("Name")
        if name in want:
            archives = [a.strip() for a in (p.findtext("DownloadableArchives") or "").split(",") if a.strip()]
            found[name] = (p.findtext("Version"), archives)
    missing = [w for w in want if w not in found]
    if missing:
        sys.exit(f"qt-fetch: not in {repo}: {', '.join(missing)}")
    with tempfile.TemporaryDirectory() as tmp:
        for name in want:
            ver, archives = found[name]
            for a in archives:
                url = f"{repo}/{name}/{ver}{a}"
                print(f"  fetch {ver}{a}", flush=True)
                data = get(url)
                published = get(url + ".sha256").decode().split()[0]
                if hashlib.sha256(data).hexdigest() != published:
                    sys.exit(f"qt-fetch: sha256 mismatch for {a}")
                path = os.path.join(tmp, a)
                with open(path, "wb") as f:
                    f.write(data)
                # ICU ships with no layout; Qt's installer files it under lib/
                target = os.path.join(prefix, "lib") if "icu-" in a else prefix
                with py7zr.SevenZipFile(path) as z:
                    z.extractall(target)
                os.remove(path)
    # .pc files name the machine the kit was built on
    pcdir = os.path.join(prefix, "lib", "pkgconfig")
    if os.path.isdir(pcdir):
        for pc in os.listdir(pcdir):
            p = os.path.join(pcdir, pc)
            lines = open(p).read().splitlines()
            lines = [f"prefix={prefix}" if l.startswith("prefix=") else l for l in lines]
            open(p, "w").write("\n".join(lines) + "\n")
    print(f"qt-fetch: Qt {version} {kit} at {prefix}")


if __name__ == "__main__":
    main()
