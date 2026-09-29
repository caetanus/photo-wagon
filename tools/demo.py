#!/usr/bin/env python3
"""Build an isolated, browsable demo through Photo Wagon's real import/face APIs."""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

from demo_ipc import DemoCore

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "docs" / "demo-photos"
FACE_MODELS = (
    "face_detection_yunet_2023mar.onnx",
    "face_recognition_sface_2021dec.onnx",
    "arcfaceresnet100-8.onnx",
)


def prepare(work, models, entries):
    for folder in ("photos", "library", "runtime", "models", "config", "data", "cache"):
        (work / folder).mkdir(parents=True, exist_ok=True)
    for model in FACE_MODELS:
        source = models / model
        if not source.is_file():
            raise FileNotFoundError(f"Required face model: {source}")
        (work / "models" / model).symlink_to(source)
    for entry in entries:
        # Work on copies: the app may write tag metadata. Keep generated assets intact.
        target = work / "photos" / entry["date"] / entry["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ASSETS / entry["file"], target)
    env = dict(os.environ, XDG_CONFIG_HOME=str(work / "config"),
               XDG_DATA_HOME=str(work / "data"), XDG_CACHE_HOME=str(work / "cache"),
               QT_FORCE_STDERR_LOGGING="1")
    for key in ("PW_SHOT", "PW_SHOT_VIEW", "PW_SHOT_OPEN", "PW_SHOT_SEND", "PW_ENDPOINT"):
        env.pop(key, None)
    ui = work / "config" / "photowagon" / "ui-state.json"
    ui.parent.mkdir(parents=True, exist_ok=True)
    ui.write_text(json.dumps({
        "theme": "gtk", "zoom": 235, "startupView": "all",
        "win": {"w": 1440, "h": 1000},
        "folded": {"dates": False, "people": True, "places": False,
                   "keywords": False, "albums": True,
                   "tags": {"scene": True, "mood": False, "weather": False, "holiday": False}},
    }))
    return env


def seed(core, work, entries):
    core.call("library.addRoot", {"path": str(work / "photos")})
    core.wait("library.stats", lambda s: s["total"] == len(entries), "Importing photos")
    photos = core.call("library.page", {"limit": 240})["items"]
    ids = {Path(p["path"]).name: p["id"] for p in photos}
    for photo in photos:
        core.call("photo.setKind", {"id": photo["id"], "kind": "photo"})
    core.call("faces.scan")
    core.wait("faces.status", lambda s: not s["running"] and s["scanned"] >= len(entries),
              "Detecting faces", timeout=600)

    albums = {}
    for entry in entries:
        photo_id = ids[entry["file"]]
        for name in entry["albums"]:
            albums.setdefault(name, []).append(photo_id)
        core.call("photo.setPlace", {"ids": [photo_id], "place": entry["place"], "country": "Brazil"})
        for group, tag in entry["tags"].items():
            if group == "weather" and tag == "Indoors":
                continue  # The vocabulary's neutral class is not a selectable tag.
            core.call("photo.setTag", {"ids": [photo_id], "group": group, "tag": tag})
        core.call("photo.addKeywords", {"ids": [photo_id], "keywords": entry["keywords"]})
        if entry.get("favorite"):
            core.call("photo.favorite", {"id": photo_id, "on": True})
    for name, photo_ids in albums.items():
        core.call("album.create", {"name": name, "photoIds": photo_ids})

    # Labels are authored demo data, applied to actual detections using the same
    # endpoint as the naming dialog. No fake faces or database rows are inserted.
    people, covers = {}, {}
    for entry in sorted(entries, key=lambda e: not e.get("portrait", False)):
        names = entry.get("people", [])
        if not names:
            continue
        faces = core.call("photo.faces", {"id": ids[entry["file"]]})["faces"]
        faces = sorted(faces, key=lambda f: f["w"] * f["h"], reverse=True)[:len(names)]
        faces.sort(key=lambda f: f["x"])
        if len(faces) != len(names):
            raise RuntimeError(f"{entry['file']}: expected {len(names)} foreground faces, got {len(faces)}")
        for name, face in zip(names, faces):
            params = {"faceId": face["id"]}
            if name in people:
                params["personId"] = people[name]
            else:
                params["name"] = name
            person = core.call("face.setPerson", params)["personId"]
            people[name] = person
            if entry.get("portrait"):
                covers[name] = face["id"]
    for name, face_id in covers.items():
        core.call("people.setCover", {"id": people[name], "faceId": face_id})
    result = {"photos": ids, "people": people,
              "stats": core.call("library.stats"),
              "persons": core.call("people.list")["people"],
              "albums": core.call("album.list")["albums"]}
    for name, person_id in people.items():
        matches = core.call("library.page", {"personId": person_id, "limit": 240})
        expected = {ids[e["file"]] for e in entries if name in e.get("people", [])}
        actual = {photo["id"] for photo in matches["items"]}
        if not expected <= actual:
            raise RuntimeError(f"Person filter for {name} is missing expected photos")
    (work / "demo.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"Ready: {len(ids)} photos, {len(people)} named people, {len(albums)} albums", flush=True)
    return result


def capture(command, env, work, output, name, extra=None, window=None):
    shot = output / name
    capture_env = dict(env, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
                       PW_SHOT=str(shot))
    capture_env.update(extra or {})
    ui = work / "config" / "photowagon" / "ui-state.json"
    saved_ui = ui.read_text() if window else None
    if window:
        state = json.loads(saved_ui)
        state["win"] = {"w": window[0], "h": window[1]}
        ui.write_text(json.dumps(state))
    try:
        with (work / (name + ".log")).open("w") as log:
            subprocess.run(command, env=capture_env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=90)
    finally:
        if saved_ui is not None:
            ui.write_text(saved_ui)
    if not shot.is_file() or shot.stat().st_size < 1024:
        raise RuntimeError(f"Capture failed: {name}; see {work / (name + '.log')}")
    print(f"Captured {shot}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, help="New demo directory (must not already exist)")
    parser.add_argument("--models", type=Path, default=ROOT / "models")
    parser.add_argument("--capture", type=Path, help="Write real desktop, people, viewer and phone captures here")
    parser.add_argument("--open", action="store_true", help="Open the prepared desktop demo")
    args = parser.parse_args()
    entries = json.loads((ASSETS / "library.json").read_text())
    missing = [entry["file"] for entry in entries if not (ASSETS / entry["file"]).is_file()]
    if missing:
        parser.error("Missing demo assets: " + ", ".join(missing))
    work = args.work.resolve() if args.work else Path(tempfile.mkdtemp(prefix="photo-wagon-demo-"))
    if args.work:
        work.mkdir(parents=True, exist_ok=False)
    print(f"Demo data: {work}", flush=True)
    env = prepare(work, args.models.resolve(), entries)
    command = [str(ROOT / "photo-wagon"), "--data", str(work / "library"),
               "--runtime", str(work / "runtime"), "--models", str(work / "models"),
               "--no-p2p", "--jobs", "2"]
    with DemoCore(command, work, env) as core:
        result = seed(core, work, entries)
    # A reusable launcher opens only this library, with its own UI preferences.
    launcher = work / "open-demo.sh"
    exports = "\n".join(f"export {key}={shlex.quote(env[key])}" for key in
                        ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "QT_FORCE_STDERR_LOGGING"))
    launcher.write_text("#!/bin/sh\n" + exports + "\nexec " + shlex.join(command) + "\n")
    launcher.chmod(0o755)
    if args.capture:
        output = args.capture.resolve()
        output.mkdir(parents=True, exist_ok=True)
        capture(command, env, work, output, "desktop.png")
        capture(command, env, work, output, "people.png", {"PW_SHOT_VIEW": "people"},
                window=(1440, 520))
        capture(command, env, work, output, "viewer.png",
                {"PW_SHOT_OPEN": str(result["photos"]["lucy-alice-praia.png"])})
        with DemoCore(command, work, env) as core:
            capture([str(ROOT / "mobile" / "photo-wagon-mobile")], env, work, output,
                    "mobile-desktop.png", {"PW_PHONE_ROOTS": str(work / "photos"),
                                   "PW_ENDPOINT": f"127.0.0.1:{core.port}"})
    print(f"Open the demo: {launcher}", flush=True)
    if args.open:
        subprocess.run(command, env=env, check=True)


if __name__ == "__main__":
    main()
