#!/usr/bin/env python3
"""Generate AppIcon.icns for SuperCaffeinate: a cream coffee cup with steam on a
brown to amber squircle. Needs Pillow, sips and iconutil. No network.

    python3 icon/make_icon.py

Writes icon/AppIcon-1024.png, icon/AppIcon.iconset/ and icon/AppIcon.icns.
"""
import os, shutil, subprocess
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
S = 4096                      # supersample, downscaled to 1024 at the end
OUT = 1024
CREAM = (255, 244, 224, 255)

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Big Sur tile: 824/1024 of the canvas, corner radius about 22.4% of the tile.
    margin = int(S * 100 / 1024)
    tile = S - 2 * margin
    radius = int(tile * 0.224)

    # Soft drop shadow under the tile.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [margin, margin + S * 0.012, S - margin, S - margin + S * 0.012],
        radius, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S * 0.012)))

    # Vertical gradient: amber at top to deep espresso at the bottom.
    top, bot = (232, 150, 58), (74, 38, 20)
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = min(max((y - margin) / tile, 0), 1)
        gd.line([(0, y), (S, y)], fill=lerp(top, bot, t) + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [margin, margin, S - margin, S - margin], radius, fill=255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    u = tile / 100.0                     # one unit = 1% of the tile
    ox, oy = margin, margin

    def P(x, y):
        return (ox + x * u, oy + y * u)

    # Saucer.
    d.ellipse([*P(16, 74), *P(84, 86)], fill=CREAM)
    d.ellipse([*P(30, 75.5), *P(70, 81)], fill=(222, 196, 160, 255))

    # Cup body: flat rim, tapering sides, rounded bottom.
    body = [P(22, 44), P(70, 44), P(64.5, 70), P(27.5, 70)]
    d.polygon(body, fill=CREAM)
    d.ellipse([*P(27.5, 62), *P(64.5, 78)], fill=CREAM)
    d.rounded_rectangle([*P(21, 41), *P(71, 47)], radius=3 * u, fill=CREAM)

    # Handle: thick ring on the right.
    w = int(5.5 * u)
    d.ellipse([*P(62, 48), *P(84, 68)], outline=CREAM, width=w)
    d.polygon([P(66, 47), P(70, 47), P(68, 66), P(63, 66)], fill=CREAM)

    # Steam: three S wisps drawn as round-capped strokes along sine curves.
    import math
    sw = int(4.2 * u)
    for cx, h0, amp in ((34, 14, 3.2), (46, 10, 3.6), (58, 14, 3.2)):
        pts = []
        for i in range(81):
            t = i / 80
            y = 36 - t * (36 - h0)
            x = cx + amp * math.sin(t * 2 * math.pi)
            pts.append(P(x, y))
        # Dense round dabs give a seamless round-capped stroke.
        r = sw / 2
        for i in range(len(pts) - 1):
            (x0, y0), (x1, y1) = pts[i], pts[i + 1]
            for k in range(12):
                x = x0 + (x1 - x0) * k / 12
                y = y0 + (y1 - y0) * k / 12
                d.ellipse([x - r, y - r, x + r, y + r], fill=CREAM)

    png = os.path.join(HERE, "AppIcon-1024.png")
    img.resize((OUT, OUT), Image.LANCZOS).save(png)

    iconset = os.path.join(HERE, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["sips", "-z", str(px), str(px), png, "--out",
                            os.path.join(iconset, name)],
                           check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o",
                    os.path.join(HERE, "AppIcon.icns")], check=True)
    print("wrote", os.path.join(HERE, "AppIcon.icns"))

if __name__ == "__main__":
    main()
