#!/usr/bin/env python3
"""
Generates resources/dmg-background.png — the window backdrop shown when a
user opens Work.dmg in Finder.

  python3 scripts/build-dmg-background.py

Layout matches the icon positions set by release.sh's AppleScript:
  - Work.app       → (130, 150)    [left slot]
  - Applications   → (370, 150)    [right slot]
  - Window bounds  → 500 × 330

Two renders are produced so Finder can pick the right DPI:
  - dmg-background.png      @1x 500x330
  - dmg-background@2x.png   @2x 1000x660 (same art)

Finder uses `.background/dmg-background.tiff` by convention, but a PNG
referenced by AppleScript also works. We ship a TIFF bundle so Retina
renders crisply.
"""

from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "resources"
OUT_DIR.mkdir(parents=True, exist_ok=True)

# Night Foundry palette (matches work.munyamakosa.com + terminal default)
GRAPHITE = (17, 17, 19)        # #111113
GRAPHITE_ELEVATED = (31, 31, 35)  # #1f1f23
IVORY = (240, 236, 228)        # #f0ece4
IVORY_MUTED = (240, 236, 228, 140)
BLUE_BRIGHT = (90, 143, 212)   # #5a8fd4


def render(scale: int) -> Image.Image:
    W, H = 500 * scale, 330 * scale
    img = Image.new("RGB", (W, H), GRAPHITE)
    draw = ImageDraw.Draw(img, "RGBA")

    # Faint vignette — a very subtle radial darkening at corners so the icon
    # slots feel centered without needing to draw explicit drop-zones.
    # Skipped in favor of a flat background for simplicity + smaller file.

    # ── Arrow between the two icon slots ────────────────────────────────
    # Icon positions: Work.app at x=130, Applications at x=370, y=150.
    # Icons are 128pt so each extends y=86..214; label text below runs to
    # ~y=230. We draw the arrow at the icons' vertical center so the two
    # icons visually anchor its ends (Finder paints them on top of the bg).
    y = 150 * scale
    x_start = (130 + 60) * scale   # just past Work.app's right edge
    x_end = (370 - 60) * scale     # just before Applications' left edge
    shaft_thickness = 3 * scale

    # Arrow shaft: gradient from graphite_elevated (left) to blue_bright (right)
    # Approximate with a handful of color stops drawn as overlapping rects.
    steps = 40
    for i in range(steps):
        t = i / (steps - 1)
        r = int(GRAPHITE_ELEVATED[0] * (1 - t) + BLUE_BRIGHT[0] * t)
        g = int(GRAPHITE_ELEVATED[1] * (1 - t) + BLUE_BRIGHT[1] * t)
        b = int(GRAPHITE_ELEVATED[2] * (1 - t) + BLUE_BRIGHT[2] * t)
        seg_x1 = int(x_start + (x_end - x_start) * (i / steps))
        seg_x2 = int(x_start + (x_end - x_start) * ((i + 1) / steps))
        draw.rectangle(
            [seg_x1, y - shaft_thickness // 2, seg_x2, y + shaft_thickness // 2],
            fill=(r, g, b, 230)
        )

    # Arrow head — filled triangle
    head_len = 14 * scale
    head_half = 8 * scale
    draw.polygon(
        [
            (x_end, y - head_half),
            (x_end, y + head_half),
            (x_end + head_len, y),
        ],
        fill=BLUE_BRIGHT
    )

    # ── Label well below the icons + their own text labels ──────────
    # Finder paints each icon's name (e.g. "Work", "Applications") just
    # under the 128pt icon, so text sits at roughly y=214..230. Anything
    # above y=240 would overlap. Drop ours to y=275 for breathing room.
    label = "Drag Work to Applications"
    font = None
    for path, size in [
        ("/System/Library/Fonts/SFNS.ttf", 13 * scale),
        ("/System/Library/Fonts/Supplemental/Arial.ttf", 13 * scale),
        ("/Library/Fonts/Arial.ttf", 13 * scale),
    ]:
        try:
            font = ImageFont.truetype(path, size)
            break
        except OSError:
            continue
    if font is None:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), label, font=font)
    text_w = bbox[2] - bbox[0]
    text_x = (W - text_w) // 2
    text_y = 275 * scale
    draw.text((text_x, text_y), label, fill=IVORY_MUTED[:3], font=font)

    # ── Top-left branding: small "W" mark ─────────────────────────────
    brand_x = 24 * scale
    brand_y = 22 * scale
    brand_size = 18 * scale
    draw.rounded_rectangle(
        [brand_x, brand_y, brand_x + brand_size, brand_y + brand_size],
        radius=4 * scale, fill=BLUE_BRIGHT
    )
    # Tiny "W" inside the square — use default font; we don't need it crisp
    try:
        brand_font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 12 * scale)
    except OSError:
        brand_font = font
    bbox = draw.textbbox((0, 0), "W", font=brand_font)
    bw = bbox[2] - bbox[0]
    bh = bbox[3] - bbox[1]
    draw.text(
        (brand_x + (brand_size - bw) // 2 - 1, brand_y + (brand_size - bh) // 2 - 2),
        "W", fill=IVORY, font=brand_font
    )

    return img


def main():
    img_1x = render(1)
    img_2x = render(2)

    png_1x = OUT_DIR / "dmg-background.png"
    png_2x = OUT_DIR / "dmg-background@2x.png"
    img_1x.save(png_1x, "PNG", optimize=True)
    img_2x.save(png_2x, "PNG", optimize=True)
    print(f"✓ {png_1x.relative_to(ROOT)} ({png_1x.stat().st_size} bytes)")
    print(f"✓ {png_2x.relative_to(ROOT)} ({png_2x.stat().st_size} bytes)")

    # The Retina-aware TIFF is built via `tiffutil -cathidpicheck` in
    # release.sh (PIL's libtiff bindings on Python 3.14 / arm64 Homebrew
    # are broken for multi-page writes as of writing).


if __name__ == "__main__":
    main()
