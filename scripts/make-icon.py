#!/usr/bin/env python3
"""Generates Resources/AppIcon.icns for VT Puncher.

Draws a macOS-style squircle icon: a blue->indigo gradient with a white
clock face (time punching) and a green "punched" checkmark badge.
Requires Pillow (`pip3 install pillow`) and macOS `iconutil`.
"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Resources")
ICONSET = os.path.join(RESOURCES, "AppIcon.iconset")
CANVAS = 1024

SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def lerp(a, b, t):
    return a + (b - a) * t


def squircle_mask(size, corner_ratio=0.225):
    """macOS Big Sur+ style continuous-curve squircle mask."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    r = int(size * corner_ratio)
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return mask


def make_base():
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    px = img.load()

    top = (74, 122, 255)      # #4A7AFF
    bottom = (91, 42, 219)    # #5B2ADB

    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        r = int(lerp(top[0], bottom[0], t))
        g = int(lerp(top[1], bottom[1], t))
        b = int(lerp(top[2], bottom[2], t))
        for x in range(CANVAS):
            px[x, y] = (r, g, b, 255)

    mask = squircle_mask(CANVAS)
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def draw_clock(img):
    draw = ImageDraw.Draw(img)
    cx, cy = CANVAS // 2 - 20, CANVAS // 2 - 20
    radius = 300

    ring_w = 46
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        outline=(255, 255, 255, 255),
        width=ring_w,
    )

    # crown tick at 12
    draw.rounded_rectangle(
        [cx - 14, cy - radius - 46, cx + 14, cy - radius + 6],
        radius=12,
        fill=(255, 255, 255, 255),
    )

    # hour ticks
    for angle_deg in (0, 90, 180, 270):
        a = math.radians(angle_deg - 90)
        inner = radius - 70
        outer = radius - 20
        x1, y1 = cx + inner * math.cos(a), cy + inner * math.sin(a)
        x2, y2 = cx + outer * math.cos(a), cy + outer * math.sin(a)
        draw.line([x1, y1, x2, y2], fill=(255, 255, 255, 255), width=26)

    # hour hand (short, pointing to ~10)
    a_hour = math.radians(-60 - 90)
    hx, hy = cx + (radius - 130) * math.cos(a_hour), cy + (radius - 130) * math.sin(a_hour)
    draw.line([cx, cy, hx, hy], fill=(255, 255, 255, 255), width=34)

    # minute hand (long, pointing to ~2)
    a_min = math.radians(55 - 90)
    mx, my = cx + (radius - 55) * math.cos(a_min), cy + (radius - 55) * math.sin(a_min)
    draw.line([cx, cy, mx, my], fill=(255, 255, 255, 255), width=26)

    draw.ellipse([cx - 22, cy - 22, cx + 22, cy + 22], fill=(255, 255, 255, 255))

    for x1, y1, x2, y2, w in (
        (cx, cy, hx, hy, 34),
        (cx, cy, mx, my, 26),
    ):
        draw.line([x1, y1, x2, y2], fill=(255, 255, 255, 255), width=w)
    draw.ellipse([cx - 22, cy - 22, cx + 22, cy + 22], fill=(255, 255, 255, 255))

    # rounded hand caps
    for x, y, w in ((hx, hy, 34), (mx, my, 26)):
        r = w / 2
        draw.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, 255))

    return cx, cy, radius


def draw_badge(img, cx, cy, radius):
    badge_r = 150
    bx = cx + radius - 40
    by = cy + radius - 40

    # subtle outer ring so the badge separates from the clock ring
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        [bx - badge_r - 14, by - badge_r - 14, bx + badge_r + 14, by + badge_r + 14],
        fill=(255, 255, 255, 255),
    )
    draw.ellipse(
        [bx - badge_r, by - badge_r, bx + badge_r, by + badge_r],
        fill=(52, 199, 89, 255),  # macOS system green
    )

    # checkmark
    check = [
        (bx - 72, by + 4),
        (bx - 20, by + 62),
        (bx + 82, by - 66),
    ]
    draw.line(check, fill=(255, 255, 255, 255), width=34, joint="curve")
    for x, y in (check[0], check[-1]):
        draw.ellipse([x - 17, y - 17, x + 17, y + 17], fill=(255, 255, 255, 255))
    mx, my = check[1]
    draw.ellipse([mx - 17, my - 17, mx + 17, my + 17], fill=(255, 255, 255, 255))


def main():
    os.makedirs(ICONSET, exist_ok=True)

    base = make_base()
    cx, cy, radius = draw_clock(base)
    draw_badge(base, cx, cy, radius)

    master_path = os.path.join(RESOURCES, "AppIcon-1024.png")
    base.save(master_path)

    for name, size in SIZES:
        resized = base.resize((size, size), Image.LANCZOS)
        resized.save(os.path.join(ICONSET, name))

    icns_path = os.path.join(RESOURCES, "AppIcon.icns")
    subprocess.run(
        ["iconutil", "-c", "icns", ICONSET, "-o", icns_path],
        check=True,
    )
    print(f"Wrote {icns_path}")


if __name__ == "__main__":
    sys.exit(main())
