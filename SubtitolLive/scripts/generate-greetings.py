#!/usr/bin/env python3
"""Generates Sources/SubtitolLive/GreetingLettering+Paths.swift: the greetings ("bon dia",
"hola", "hello", "ola", "kaixo") that write themselves at the top of the languages screen.

The letters are a monoline script built from upright ovals and straight lines: narrow
bowls, compact loops, a small hook at the baseline that turns each downstroke into the
next letter. A word is one pen path, which the app strokes with one continuous
gradient, so nothing marks where one letter ends and the next begins.

    python3 SubtitolLive/scripts/generate-greetings.py            # writes the Swift file
    python3 SubtitolLive/scripts/generate-greetings.py --svg x.html   # preview page

Units: baseline at y 0, x-height at y -100 (SVG, y down), ascenders at -172. Upright;
the view slants it.
"""
import math
import sys
from pathlib import Path

H = 100          # x-height
R = 38           # bowl half-width: upright ovals, not circles
RY = 46          # bowl half-height
ASC = -172       # ascender top
HOOK = 22        # height of the baseline hook
HOOK_W = 17      # its width
KAPPA = 0.5522847498


class Pen:
    """Collects cubic segments; tracks position and heading."""

    def __init__(self, start, heading):
        self.pos = start
        self.heading = heading
        self.segs = []

    def cubic(self, c1, c2, p):
        self.segs.append((c1, c2, p))
        dx, dy = p[0] - c2[0], p[1] - c2[1]
        n = math.hypot(dx, dy) or 1
        self.heading = (dx / n, dy / n)
        self.pos = p

    def line(self, p):
        a = self.pos
        self.cubic((a[0] + (p[0] - a[0]) / 3, a[1] + (p[1] - a[1]) / 3),
                   (a[0] + 2 * (p[0] - a[0]) / 3, a[1] + 2 * (p[1] - a[1]) / 3), p)

    def arc(self, centre, r, a0, a1, ry=None):
        """Arc of a circle (or, with ry, of an upright ellipse r wide and ry tall) from
        angle a0 to a1 (degrees, SVG angles: 90 points down)."""
        rx, ry = r, (ry if ry is not None else r)
        steps = max(1, math.ceil(abs(a1 - a0) / 90))
        da = (a1 - a0) / steps
        for i in range(steps):
            t0 = math.radians(a0 + da * i)
            t1 = math.radians(a0 + da * (i + 1))
            k = 4 / 3 * math.tan((t1 - t0) / 4)
            p0 = (centre[0] + rx * math.cos(t0), centre[1] + ry * math.sin(t0))
            p1 = (centre[0] + rx * math.cos(t1), centre[1] + ry * math.sin(t1))
            c1 = (p0[0] - k * rx * math.sin(t0), p0[1] + k * ry * math.cos(t0))
            c2 = (p1[0] + k * rx * math.sin(t1), p1[1] - k * ry * math.cos(t1))
            self.cubic(c1, c2, p1)

    def join(self, p, heading, reach=0.42):
        """A smooth curve from the pen to p, leaving along the pen's heading and
        arriving along `heading`."""
        a = self.pos
        d = math.hypot(p[0] - a[0], p[1] - a[1]) * reach
        self.cubic((a[0] + self.heading[0] * d, a[1] + self.heading[1] * d),
                   (p[0] - heading[0] * d, p[1] - heading[1] * d), p)

    def hook(self, x):
        """From a downstroke at x: down to the hook, round into the baseline, heading right."""
        self.line((x, -HOOK))
        self.arc((x + HOOK_W, -HOOK), HOOK_W, 180, 90, HOOK)


UP, DOWN, RIGHT = (0, -1), (0, 1), (1, 0)

# Each letter: (advance, draw(pen, x)) and optional extra strokes (dots, crossbars) drawn
# after the word as separate pieces.


def loop_stem(p, x, hooked=True, reach=0.42):
    """An ascender loop whose stem sits at x + 8: up the right side, round the top, down."""
    stem = x + 8
    cx = stem + 20
    p.join((cx + 20, -150), UP, reach)
    p.arc((cx, -150), 20, 0, -180, 24)
    if hooked:
        p.hook(stem)
    else:
        p.line((stem, 0))


def hump(p, stem, top=-100):
    """Back up the stem and over a narrow round hump to the next downstroke."""
    rx, ry = 28, 33
    p.line((stem, top + ry))
    p.arc((stem + rx, top + ry), rx, 180, 360, ry)
    p.hook(stem + 2 * rx)


def bowl(p, x):
    """A full oval bowl, entered on its left going up, clockwise; ends at its top heading right."""
    c = (x + R, -RY - 2)
    p.join((x, c[1]), UP)
    p.arc(c, R, 180, 540, RY)
    p.arc(c, R, 180, 270, RY)
    return c


def l_(p, x):
    loop_stem(p, x)
    return 8 + 2 * HOOK_W + 6


def h_(p, x):
    loop_stem(p, x, hooked=False)
    hump(p, x + 8)
    return 8 + 56 + 2 * HOOK_W + 6


def k_(p, x):
    """Stem, then an arm that loops round a small oval and kicks out to the baseline."""
    loop_stem(p, x, hooked=False)
    stem = x + 8
    p.line((stem, -50))
    p.join((stem + 32, -H), RIGHT, 0.5)
    p.arc((stem + 32, -H + 19), 14, -90, 90, 19)
    p.line((stem + 12, -58))
    p.line((stem + 38, -HOOK - 2))
    p.join((stem + 56, 0), RIGHT, 0.45)
    return 76


def b_(p, x):
    loop_stem(p, x, hooked=False)
    stem = x + 8
    p.line((stem, -RY - 2))
    c = (stem + R, -RY - 2)
    p.arc(c, R, 180, 540, RY)
    p.arc(c, R, 180, 270, RY)
    return 8 + 2 * R + 12


def o_(p, x):
    bowl(p, x + 4)
    return 4 + 2 * R + 12


def a_(p, x):
    c = bowl(p, x + 4)
    p.arc(c, R, 270, 360, RY)
    p.hook(c[0] + R)
    return 4 + 2 * R + 2 * HOOK_W + 6


def d_(p, x):
    c = bowl(p, x + 4)
    stem = c[0] + R
    p.join((stem + 4, ASC), UP, 0.5)
    p.line((stem, -60))
    p.hook(stem)
    return 4 + 2 * R + 2 * HOOK_W + 6


def i_(p, x):
    p.join((x + 8, -H), UP)
    p.hook(x + 8)
    return 8 + 2 * HOOK_W + 4


def n_(p, x):
    p.join((x + 8, -H), UP)
    p.line((x + 8, 0))
    hump(p, x + 8)
    return 8 + 56 + 2 * HOOK_W + 6


def e_(p, x):
    """A rising chord from lower left to upper right closes a small eye with the top of
    the oval; the stroke then runs on anticlockwise round the left and the bottom."""
    rx, ry = 35, 42
    c = (x + rx + 4, -ry - 4)
    on = lambda a: (c[0] + rx * math.cos(math.radians(a)), c[1] + ry * math.sin(math.radians(a)))
    p.join(on(158), (0.8, -0.6), 0.4)
    p.line(on(-28))
    p.arc(c, rx, -28, -300, ry)
    return 2 * rx + 14


def x_(p, x):
    """One stroke from top left down to the hook; the crossbar comes after the word."""
    p.join((x + 10, -H), UP, 0.45)
    p.line((x + 44, -HOOK - 4))
    p.join((x + 62, 0), RIGHT, 0.45)
    return 70


LETTERS = {"l": l_, "h": h_, "k": k_, "b": b_, "o": o_, "a": a_, "d": d_, "i": i_, "n": n_, "e": e_, "x": x_}
EXTRAS = {
    "i": lambda x: [[(x + 14, -144), (x + 14.5, -144.5)]],
    "x": lambda x: [[(x + 52, -H), (x + 6, -2)]],
}
LEAD_IN = 34
SPACE = 56


def word(text):
    """Pieces in drawing order: (segments, start point). Each letter is one piece that
    begins where the previous one ended; extras follow the word."""
    pieces, extras = [], []
    x = 0
    pen = None
    for ch in text:
        if ch == " ":
            pen = None
            x += SPACE
            continue
        if pen is None:
            pen = Pen((x - LEAD_IN, -4), (1, -0.15))
        start = pen.pos
        pen.segs = []
        adv = LETTERS[ch](pen, x)
        pieces.append((start, list(pen.segs)))
        for e in EXTRAS.get(ch, lambda _: [])(x):
            a, b = e
            extras.append((a, [(a, b, b)] if math.hypot(b[0]-a[0], b[1]-a[1]) < 2 else
                           [((a[0] + (b[0]-a[0]) / 3, a[1] + (b[1]-a[1]) / 3),
                             (a[0] + 2*(b[0]-a[0]) / 3, a[1] + 2*(b[1]-a[1]) / 3), b)]))
        x += adv
    return pieces + extras


def seg_length(p0, seg):
    c1, c2, p = seg
    n, total, prev = 24, 0.0, p0
    for i in range(1, n + 1):
        t = i / n
        u = 1 - t
        q = (u**3 * p0[0] + 3*u*u*t*c1[0] + 3*u*t*t*c2[0] + t**3 * p[0],
             u**3 * p0[1] + 3*u*u*t*c1[1] + 3*u*t*t*c2[1] + t**3 * p[1])
        total += math.hypot(q[0] - prev[0], q[1] - prev[1])
        prev = q
    return total


def piece_length(start, segs):
    total, pos = 0.0, start
    for seg in segs:
        total += max(seg_length(pos, seg), 3)   # a dot still takes a moment
        pos = seg[2]
    return total


GREETINGS = {"ca": "bon dia", "gl": "ola", "eu": "kaixo", "es": "hola", "en": "hello"}
TONES = 4


def d_attr(start, segs):
    out = [f"M {start[0]:.1f} {start[1]:.1f}"]
    for c1, c2, p in segs:
        out.append(f"C {c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {p[0]:.1f} {p[1]:.1f}")
    return " ".join(out)


def pt(p):
    return f"CGPoint(x: {p[0]:.1f}, y: {p[1]:.1f})"


def swift():
    lines = [
        "// Generated by scripts/generate-greetings.py. Edit the letters there, not here.",
        "import CoreGraphics",
        "",
        "extension GreetingLettering {",
        "    /// Each language's greeting as one pen path (dots and crossbars last), in letter",
        "    /// units: baseline at 0, x-height at -100. Upright; the view slants it.",
        "    static let greetings: [String: (text: String, path: CGPath)] = [",
    ]
    for language, text in GREETINGS.items():
        lines.append(f'        "{language}": ("{text}", {{')
        lines.append("            let path = CGMutablePath()")
        for start, segs in word(text):
            lines.append(f"            path.move(to: {pt(start)})")
            for c1, c2, p in segs:
                lines.append(f"            path.addCurve(to: {pt(p)}, control1: {pt(c1)}, control2: {pt(c2)})")
        lines.append("            return path")
        lines.append("        }()),")
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def preview():
    rows, y = [], 210
    for text in GREETINGS.values():
        d = " ".join(d_attr(st, g) for st, g in word(text))
        rows.append(f'<g transform="translate(90,{y}) skewX(-12)"><path d="{d}" stroke="url(#ink)"/></g>')
        y += 230
    return (f'<html><body style="margin:0;background:#FAFAF9"><svg viewBox="0 0 900 {y}" width="900">'
            '<defs><linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="-40" x2="560">'
            '<stop offset="0" stop-color="#FF6400"/><stop offset="1" stop-color="#FFB000"/></linearGradient></defs>'
            f'<g style="fill:none;stroke-width:19;stroke-linecap:round;stroke-linejoin:round">'
            f'{"".join(rows)}</g></svg></body></html>')


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--svg":
        Path(sys.argv[2]).write_text(preview())
    else:
        target = Path(__file__).resolve().parent.parent / "Sources/SubtitolLive/GreetingLettering+Paths.swift"
        target.write_text(swift())
        print(target)
