#!/usr/bin/env python3
"""Genera les icones de la PWA 'Català ASR' — brutalista geomètric en blanc i negre.

Marca: un mig disc (la veu) i tres blocs en escala que es tornen text, l'últim
un quadrat com el cursor. Tot sobre una graella de 32 px en un llenç de 512.
Escriu web/icon.svg i les PNG (renderitzades a 4x i reduïdes amb LANCZOS).
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent / "web"
SS = 4  # supersampling
SIZE = 512
INK = "#ffffff"
PAPER = "#000000"

# Geometria en unitats del llenç de 512 (graella de 32).
DISC = (224, 256, 128)  # centre x, centre y, radi: mig disc cap a l'esquerra
BARS = [(256, 128, 416, 192), (256, 224, 384, 288), (256, 320, 320, 384)]


def svg(scale=1.0):
    t = lambda v: round(256 + (v - 256) * scale, 2)
    cx, cy, r = DISC
    rr = round(r * scale, 2)
    parts = [
        f'<path d="M{t(cx)} {t(cy - r)}A{rr} {rr} 0 0 0 {t(cx)} {t(cy + r)}Z"/>'
    ]
    for x0, y0, x1, y1 in BARS:
        parts.append(
            f'<rect x="{t(x0)}" y="{t(y0)}" width="{round((x1 - x0) * scale, 2)}" '
            f'height="{round((y1 - y0) * scale, 2)}"/>'
        )
    body = "\n    ".join(parts)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">\n'
        f'  <rect width="512" height="512" fill="{PAPER}"/>\n'
        f'  <g fill="{INK}">\n    {body}\n  </g>\n</svg>\n'
    )


def raster(scale=1.0):
    W = SIZE * SS
    img = Image.new("RGB", (W, W), PAPER)
    d = ImageDraw.Draw(img)
    t = lambda v: (256 + (v - 256) * scale) * SS
    cx, cy, r = DISC
    rr = r * scale * SS
    d.pieslice([t(cx) - rr, t(cy) - rr, t(cx) + rr, t(cy) + rr], 90, 270, fill=INK)
    for x0, y0, x1, y1 in BARS:
        d.rectangle([t(x0), t(y0), t(x1) - 1, t(y1) - 1], fill=INK)
    return img


def save(img, name, size):
    img.resize((size, size), Image.LANCZOS).save(ROOT / "icons" / name)


(ROOT / "icon.svg").write_text(svg())

full = raster()
save(full, "icon-512.png", 512)
save(full, "icon-192.png", 192)
save(full, "apple-touch-icon.png", 180)

# Maskable: la mateixa composició dins la zona segura (cercle del 80 %)
save(raster(scale=0.82), "maskable-512.png", 512)

print("icons generated")
