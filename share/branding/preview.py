#!/usr/bin/env python3
"""Build a contact sheet from the exported SVGs; no hand-retouched previews."""
from copy import deepcopy
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def node(tag, **attrs):
    return ET.Element(f"{{{SVG}}}{tag}", {k: str(v) for k, v in attrs.items()})


root = node("svg", viewBox="0 0 1280 840", width=1280, height=840)
defs = node("defs")
root.append(defs)
master = ET.parse(HERE / "master.svg").getroot()
parts = {e.get("id"): e for e in master.iter() if e.get("id")}
defs.append(deepcopy(parts["tile"]))
for name, shape in (("circle", node("circle", cx=54, cy=54, r=36)),
                    ("rounded", node("rect", x=18, y=18, width=72, height=72, rx=18))):
    clip = node("clipPath", id=f"mask-{name}")
    clip.append(shape)
    defs.append(clip)
    symbol = node("symbol", id=name, viewBox="18 18 72 72")
    group = node("g", **{"clip-path": f"url(#mask-{name})"})
    group.extend([deepcopy(parts["background"]), deepcopy(parts["mark"])])
    symbol.append(group)
    defs.append(symbol)

desktop = ET.parse(HERE.parent / "photo-wagon.svg").getroot()
symbol = node("symbol", id="desktop", viewBox="0 0 108 108")
symbol.extend(deepcopy(e) for e in desktop if not e.tag.endswith("defs"))
defs.append(symbol)
mono = deepcopy(parts["monochrome"])
mono.set("fill", "currentColor")
symbol = node("symbol", id="themed", viewBox="18 18 72 72")
symbol.append(mono)
defs.append(symbol)


def rect(x, y, w, h, fill, rx=0):
    root.append(node("rect", x=x, y=y, width=w, height=h, fill=fill, rx=rx))


def text(x, y, value, color, size=16, weight=400):
    t = node("text", x=x, y=y, fill=color, **{
        "font-family": "Noto Sans, sans-serif", "font-size": size, "font-weight": weight,
    })
    t.text = value
    root.append(t)


def icon(name, x, y, size, color=None):
    a = dict(href=f"#{name}", x=x, y=y, width=size, height=size)
    if color:
        a["color"] = color
    root.append(node("use", **a))


rect(0, 0, 640, 840, "#F4F1E9")
rect(640, 0, 640, 840, "#0C151C")
text(56, 70, "Photo Wagon", "#183A44", 36, 650)
text(56, 108, "Fotografias que vão com você.", "#66767A", 17)
text(696, 70, "Uma marca, em qualquer tema.", "#ECF0E9", 24, 550)
text(696, 108, "Desktop · Android · ícone temático", "#93AAA9", 17)
for start, fg, muted in ((0, "#183A44", "#66767A"), (640, "#ECF0E9", "#93AAA9")):
    text(start + 56, 166, "MODO CLARO" if start == 0 else "MODO ESCURO", muted, 12, 650)
    icon("desktop", start + 184, 188, 272)
    text(start + 56, 510, "RECORTES DO ANDROID", muted, 12, 650)
    icon("circle", start + 68, 544, 88)
    icon("rounded", start + 204, 544, 88)
    tint_bg, tint_fg = ("#DCE8D5", "#234C43") if start == 0 else ("#283F38", "#BCE5CB")
    rect(start + 340, 544, 88, 88, tint_bg, 24)
    icon("themed", start + 340, 544, 88, tint_fg)
    text(start + 75, 663, "Circular", muted, 12)
    text(start + 205, 663, "Adaptativo", muted, 12)
    text(start + 354, 663, "Temático", muted, 12)
    text(start + 56, 721, "TAMANHO REAL", muted, 12, 650)
    for x, size in ((64, 48), (156, 32), (232, 24), (300, 16)):
        icon("desktop", start + x, 749 + 48 - size, size)
        text(start + x, 818, f"{size} px", muted, 11)

ET.indent(root, space="  ")
ET.ElementTree(root).write(HERE / "preview.svg", encoding="utf-8", xml_declaration=True)
subprocess.run(["rsvg-convert", str(HERE / "preview.svg"), "-o", str(HERE / "preview.png")], check=True)
