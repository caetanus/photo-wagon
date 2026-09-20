#!/usr/bin/env python3
"""Export the editable SVG mark to desktop and Android resources (needs rsvg-convert)."""
from copy import deepcopy
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SVG = "http://www.w3.org/2000/svg"
ANDROID = "http://schemas.android.com/apk/res/android"
ET.register_namespace("", SVG)
ET.register_namespace("android", ANDROID)
master = ET.parse(HERE / "master.svg").getroot()


def element(tag, **attrs):
    return ET.Element(f"{{{SVG}}}{tag}", attrs)


def part(name):
    return deepcopy(next(e for e in master.iter() if e.get("id") == name))


def document(*parts):
    root = element("svg", viewBox="0 0 108 108")
    defs = element("defs")
    defs.append(part("tile"))
    root.append(defs)
    root.extend(parts)
    return root


def write_svg(path, root):
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def png(source, target, size):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size),
                    str(source), "-o", str(target)], check=True)


# Desktop / legacy icons already include their rounded tile. Adaptive layers do not.
tile = part("background")
tile.attrib.update(x="4", y="4", width="100", height="100", rx="25")
tile.set("stroke", "#42606A")
tile.set("stroke-width", "0.6")
mark = part("mark")
mark.set("transform", "translate(54 54) scale(1.24) translate(-54 -54)")
legacy = document(tile, mark)
write_svg(ROOT / "share/photo-wagon.svg", legacy)
for size in (48, 128, 256, 512):
    png(ROOT / "share/photo-wagon.svg", ROOT / f"share/icon-{size}.png", size)
png(ROOT / "share/photo-wagon.svg", ROOT / "qml/icon.png", 256)
png(ROOT / "share/photo-wagon.svg", HERE / "icon-1024.png", 1024)

art = ROOT / "mobile/android/art"
write_svg(art / "ic_legacy.svg", deepcopy(legacy))
write_svg(art / "ic_background.svg", document(part("background")))
write_svg(art / "ic_foreground.svg", document(part("mark")))
write_svg(art / "ic_monochrome.svg", document(part("monochrome")))

res = ROOT / "mobile/android/res"
for density, scale in (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2),
                       ("xxhdpi", 3), ("xxxhdpi", 4)):
    out = res / f"mipmap-{density}"
    png(art / "ic_legacy.svg", out / "ic_launcher.png", round(48 * scale))
    for layer in ("foreground", "background"):
        png(art / f"ic_{layer}.svg", out / f"ic_launcher_{layer}.png", round(108 * scale))

# Android's themed launcher uses alpha, with colors supplied by the system.
# Keeping these as paths preserves sharp edges at every launcher density.
vector = ET.Element("vector", {
    f"{{{ANDROID}}}width": "108dp", f"{{{ANDROID}}}height": "108dp",
    f"{{{ANDROID}}}viewportWidth": "108", f"{{{ANDROID}}}viewportHeight": "108",
})
for source in part("monochrome"):
    attrs = {f"{{{ANDROID}}}fillColor": "#FFFFFFFF",
             f"{{{ANDROID}}}pathData": source.attrib["d"]}
    if source.get("fill-rule") == "evenodd":
        attrs[f"{{{ANDROID}}}fillType"] = "evenOdd"
    ET.SubElement(vector, "path", attrs)
out = res / "drawable/ic_launcher_monochrome.xml"
out.parent.mkdir(parents=True, exist_ok=True)
ET.indent(vector, space="    ")
ET.ElementTree(vector).write(out, encoding="utf-8", xml_declaration=True)
print("Exported desktop, QML, Android legacy/adaptive and themed icons.")
