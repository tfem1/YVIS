#!/usr/bin/env python3
"""Generates the GraveyardOS wallpaper concepts as SVG (1920x1080 viewBox, scalable).
Deterministic: a fixed seed per wallpaper, so renders are reproducible."""
import math, random, os, sys

W, H = 1920, 1080
OUT = sys.argv[1] if len(sys.argv) > 1 else "."
V, NIGHT = "#8B5CF6", "#13101C"

def svg(body, defs="", bg=NIGHT):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
            f'width="{W}" height="{H}" preserveAspectRatio="xMidYMid slice">'
            f'<defs>{defs}</defs><rect width="{W}" height="{H}" fill="{bg}"/>{body}</svg>')

GRAIN = ('<filter id="grain" x="0" y="0" width="100%" height="100%">'
         '<feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="7"/>'
         '<feColorMatrix values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 0.05 0"/></filter>')
grain = f'<rect width="{W}" height="{H}" filter="url(#grain)"/>'

def stars(rng, n, ymax, r=(0.6, 1.6), op=(0.25, 0.9)):
    out = []
    for _ in range(n):
        x, y = rng.uniform(0, W), rng.uniform(0, ymax)
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{rng.uniform(*r):.2f}" '
                   f'fill="#EEEAF6" opacity="{rng.uniform(*op):.2f}"/>')
    return "".join(out)

# The open Y of the logo (viewBox 256), placed with a transform.
def logo(tx, ty, s, branch=V, body="#FFFFFF", sw=28, op=1.0):
    return (f'<g transform="translate({tx} {ty}) scale({s})" opacity="{op}" fill="none" '
            f'stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="M76 50 L105.4 93" stroke="{branch}"/>'
            f'<path d="M180 50 L128 126 L128 204" stroke="{body}"/></g>')

def neon():
    # The open Y large on the right, lit like a neon sign: one smooth glow.
    defs = GRAIN + ('<radialGradient id="g" cx="68%" cy="50%" r="70%">'
                    '<stop offset="0" stop-color="#231a3d"/><stop offset="1" stop-color="#0d0a14"/></radialGradient>'
                    '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%">'
                    '<feGaussianBlur stdDeviation="22"/></filter>')
    body = f'<rect width="{W}" height="{H}" fill="url(#g)"/>'
    body += (f'<g filter="url(#glow)" opacity="0.75">{logo(1000, 140, 3.3, body="#8f7ad8", sw=40)}</g>')
    body += logo(1000, 140, 3.3)
    return svg(body + grain, defs)

def aurore():
    rng = random.Random(2)
    defs = GRAIN + ('<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">'
                    '<stop offset="0" stop-color="#07060c"/><stop offset="0.7" stop-color="#161028"/>'
                    '<stop offset="1" stop-color="#21173a"/></linearGradient>'
                    '<filter id="blur" x="-20%" y="-50%" width="140%" height="200%"><feGaussianBlur stdDeviation="38"/></filter>'
                    '<linearGradient id="rib" x1="0" y1="0" x2="1" y2="0">'
                    '<stop offset="0" stop-color="#5b3fd1" stop-opacity="0"/><stop offset="0.35" stop-color="#8B5CF6"/>'
                    '<stop offset="0.7" stop-color="#C084FC"/><stop offset="1" stop-color="#7C8CF8" stop-opacity="0"/></linearGradient>')
    body = f'<rect width="{W}" height="{H}" fill="url(#sky)"/>' + stars(rng, 260, 700)
    for k, (y, a, op) in enumerate([(360, 120, 0.55), (300, 90, 0.35), (430, 70, 0.3)]):
        pts = []
        for x in range(-100, W + 101, 40):
            pts.append((x, y + a * math.sin(x / (380 + 70 * k) + k) + 30 * math.sin(x / 130 + 2 * k)))
        d = "M" + " L".join(f"{x},{yy:.1f}" for x, yy in pts)
        body += f'<path d="{d}" stroke="url(#rib)" stroke-width="{90 - 20 * k}" fill="none" filter="url(#blur)" opacity="{op}"/>'
    # hills
    for i, (base, col) in enumerate([(860, "#120d1f"), (920, "#0c0915"), (990, "#07060b")]):
        pts = [(x, base + 40 * math.sin(x / (260 + 90 * i) + i * 1.7) + 18 * math.sin(x / 90 + i)) for x in range(0, W + 41, 40)]
        d = f"M0,{H} L" + " L".join(f"{x},{y:.1f}" for x, y in pts) + f" L{W},{H} Z"
        body += f'<path d="{d}" fill="{col}"/>'
    return svg(body + grain, defs)

def dunes(day=False):
    rng = random.Random(3)
    if day:
        sky = ('<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F4F2F8"/>'
               '<stop offset="1" stop-color="#E4DCF7"/></linearGradient>')
        layers = ["#D9CCF8", "#C4AEF5", "#A98BF0", "#8B5CF6", "#6D28D9", "#4C1D95"]
        sun, sunc = (1380, 420, 120), "#FFFFFF"
    else:
        sky = ('<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0d0a14"/>'
               '<stop offset="1" stop-color="#2a1d4d"/></linearGradient>')
        layers = ["#2e2152", "#3b2a6b", "#4c3489", "#5f40a8", "#2a1f47", "#16111f"]
        sun, sunc = (1380, 400, 110), "#EEEAF6"
    body = f'<rect width="{W}" height="{H}" fill="url(#sky)"/>'
    if not day:
        body += stars(rng, 140, 520, op=(0.2, 0.7))
    body += f'<circle cx="{sun[0]}" cy="{sun[1]}" r="{sun[2]}" fill="{sunc}" opacity="{0.9 if day else 0.85}"/>'
    for i, col in enumerate(layers):
        base = 560 + i * 85
        ph = rng.uniform(0, 6)
        pts = [(x, base + 55 * math.sin(x / (420 - 30 * i) + ph) + 20 * math.sin(x / 150 + ph * 2)) for x in range(0, W + 41, 40)]
        d = f"M0,{H} L" + " L".join(f"{x},{y:.1f}" for x, y in pts) + f" L{W},{H} Z"
        body += f'<path d="{d}" fill="{col}"/>'
    return svg(body + grain, sky + GRAIN)

def branches():
    # The detached branch of the logo as a pattern: rounded capsules on a grid, mostly dark.
    rng = random.Random(4)
    body = ""
    step = 96
    for gy in range(-1, H // step + 2):
        for gx in range(-1, W // step + 2):
            x, y = gx * step + (step / 2 if gy % 2 else 0), gy * step
            r = rng.random()
            if r < 0.07:
                col, op = V, 1
            elif r < 0.12:
                col, op = "#EEEAF6", 0.9
            else:
                col, op = "#241d36", 1
            body += (f'<path d="M{x - 15:.0f} {y - 22:.0f} L{x + 15:.0f} {y + 22:.0f}" stroke="{col}" '
                     f'stroke-width="18" stroke-linecap="round" opacity="{op}"/>')
    return svg(body + grain, GRAIN)

def nebuleuse():
    rng = random.Random(5)
    defs = GRAIN + '<filter id="b" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="140"/></filter>'
    body = ""
    for cx, cy, r, col, op in [(520, 380, 420, "#8B5CF6", 0.55), (1420, 760, 480, "#4F46E5", 0.45),
                               (1300, 240, 300, "#C084FC", 0.35), (380, 900, 300, "#6D28D9", 0.4)]:
        body += f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{col}" opacity="{op}" filter="url(#b)"/>'
    body += stars(rng, 90, H, r=(0.5, 1.2), op=(0.2, 0.6))
    body += logo(W - 150, H - 150, 0.42, op=0.85)
    return svg(body + grain, defs, bg="#0b0912")

WALLS = {
    "1-neon": neon, "2-aurore": aurore, "3-dunes-nuit": dunes,
    "4-dunes-jour": lambda: dunes(day=True), "5-branches": branches, "6-nebuleuse": nebuleuse,
}
os.makedirs(OUT, exist_ok=True)
for name, f in WALLS.items():
    with open(os.path.join(OUT, f"graveyard-{name}.svg"), "w") as fh:
        fh.write(f())
print("\n".join(WALLS))
