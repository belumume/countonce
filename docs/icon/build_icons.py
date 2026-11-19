"""Build every CountOnce icon from one master: the amber tag with "1x" in IBM Plex Mono SemiBold.

The glyphs are read from app/fonts/IBMPlexMono-SemiBold.ttf and written as paths, so no icon
depends on a font at use time. Sizes of 32 px and below use a pixel-fitted drawing of the same
mark (thicker strokes on whole pixels), because the font outline turns to blur at that size.

Run from the repo root:  python docs/icon/build_icons.py
Needs fontTools, Pillow, Node and Playwright (set PLAYWRIGHT_PKG and CHROME_EXE, see render.mjs).
"""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WORK = HERE / "build"
FONT = ROOT / "app/fonts/IBMPlexMono-SemiBold.ttf"

AMBER = "#F2B21B"
INK = "#1A1D21"
PAPER = "#F5F3EE"

# The "1x" ink box in font units (Plex Mono SemiBold): "1" spans x 40..572, y 0..698; the
# multiply sign is drawn one advance (600) to the right. Centre on the box of both glyphs,
# vertically on the cap height of the "1".
INK_X0, INK_X1, INK_Y0, INK_Y1 = 40, 1125, 0, 698


def glyph_path() -> str:
    """Both glyphs as one SVG path in font units, y pointing down, origin at the ink-box centre."""
    font = TTFont(FONT)
    cmap = font.getBestCmap()
    glyphs = font.getGlyphSet()
    cx = (INK_X0 + INK_X1) / 2
    cy = (INK_Y0 + INK_Y1) / 2
    pen = SVGPathPen(glyphs, ntos=lambda v: f"{v:g}")
    for i, ch in enumerate("1×"):
        tpen = TransformPen(pen, (1, 0, 0, -1, i * 600 - cx, cy))
        glyphs[cmap[ord(ch)]].draw(tpen)
    return pen.getCommands()


def svg(view: float, body: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {view:g} {view:g}">{body}</svg>'


def glyphs_at(
    path: str, size: float, font_size: float, dy: float = 0, colour: str = INK
) -> str:
    """The glyph path scaled so 1000 font units = font_size, centred in a size x size square."""
    k = font_size / 1000
    return f'<path fill="{colour}" transform="translate({size / 2:g} {size / 2 + dy:g}) scale({k:g})" d="{path}"/>'


def tag(size: float, radius_ratio: float = 0.2) -> str:
    r = size * radius_ratio
    return f'<rect width="{size:g}" height="{size:g}" rx="{r:g}" fill="{AMBER}"/>'


def full(size: float, colour: str = AMBER) -> str:
    return f'<rect width="{size:g}" height="{size:g}" fill="{colour}"/>'


# ---- pixel-fitted small drawings --------------------------------------------------------------
# Same parts as the font glyph: a "1" with a flag and a foot, and a multiply sign. Coordinates are
# in pixels of the target size; vertical and horizontal edges sit on whole pixels.


def small_16() -> str:
    one = (
        '<path fill="#1A1D21" d="'
        "M4 3H6V11H8V13H2V11H4V6.2L2.9 7.3 1.8 6.2Z"  # stem, foot, flag
        '"/>'
    )
    times = _times(9.2, 5.6, 14.6, 11, 1.95)
    return svg(16, tag(16, 3 / 16) + one + times)


def small_32() -> str:
    one = '<path fill="#1A1D21" d="M9 7H13V22H16V25H5V22H9V12.4L6.9 14.5 4.8 12.4Z"/>'
    times = _times(18.4, 11.6, 27.6, 20.8, 3.2)
    return svg(32, tag(32, 6 / 32) + one + times)


def _times(x0: float, y0: float, x1: float, y1: float, t: float) -> str:
    """A multiply sign filling the box (x0, y0)-(x1, y1) with bars t pixels thick."""
    return (
        f'<path stroke="{INK}" stroke-width="{t:g}" stroke-linecap="butt" '
        f'd="M{x0:g} {y0:g}L{x1:g} {y1:g}M{x1:g} {y0:g}L{x0:g} {y1:g}"/>'
    )


# ---- variants ---------------------------------------------------------------------------------


def variants(p: str) -> dict[str, str]:
    m = 1024
    return {
        # The mark as the site and app draw it: tag, radius 20 %, glyphs at 45 % of the side.
        "mark": svg(m, tag(m) + glyphs_at(p, m, 0.45 * m)),
        # Full-bleed amber for platforms that cut their own shape (iOS, maskable PWA).
        "full": svg(m, full(m) + glyphs_at(p, m, 0.40 * m)),
        # Android adaptive foreground: 108 dp canvas, glyphs at 45 % of the 72 dp visible area.
        "fg": svg(108, glyphs_at(p, 108, 0.45 * 72)),
        # Legacy launcher icon (Android < 8): the tag inset to 44 of 48 dp, as Material asks.
        "legacy": svg(
            48,
            f'<g transform="translate(2 2)">{tag(44)}{glyphs_at(p, 44, 0.45 * 44)}</g>',
        ),
        # Pre-Android-12 start screen: the tag at 80 of 96 dp, centred on a transparent canvas.
        "launch": svg(
            96,
            f'<g transform="translate(8 8)">{tag(80)}{glyphs_at(p, 80, 0.45 * 80)}</g>',
        ),
        "s16": small_16(),
        "s32": small_32(),
    }


A = ROOT / "app/android/app/src/main/res"
DENS = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

OUTPUTS: list[tuple[str, int, Path, bool]] = [  # variant, size, path, opaque
    ("s32", 32, ROOT / "public/favicon-32.png", False),
    ("full", 180, ROOT / "public/apple-touch-icon.png", True),
    ("mark", 192, ROOT / "public/icon-192.png", False),
    ("mark", 512, ROOT / "public/icon-512.png", False),
    ("full", 192, ROOT / "public/icon-maskable-192.png", True),
    ("full", 512, ROOT / "public/icon-maskable-512.png", True),
    ("s32", 32, ROOT / "app/web/favicon.png", False),
    ("mark", 192, ROOT / "app/web/icons/Icon-192.png", False),
    ("mark", 512, ROOT / "app/web/icons/Icon-512.png", False),
    ("full", 192, ROOT / "app/web/icons/Icon-maskable-192.png", True),
    ("full", 512, ROOT / "app/web/icons/Icon-maskable-512.png", True),
]
for d, k in DENS.items():
    OUTPUTS += [
        ("legacy", round(48 * k), A / f"mipmap-{d}/ic_launcher.png", False),
        ("fg", round(108 * k), A / f"mipmap-{d}/ic_launcher_foreground.png", False),
        ("launch", round(96 * k), A / f"mipmap-{d}/launch_mark.png", False),
    ]

ICO_PARTS = [("s16", 16), ("s32", 32), ("mark", 48)]


def clean_png(src: Path, dst: Path, opaque: bool) -> None:
    """Re-encode from raw pixels so no ancillary chunk (text, time, EXIF) survives."""
    im = Image.open(src).convert("RGBA")
    if opaque:
        bg = Image.new("RGBA", im.size, AMBER)
        bg.alpha_composite(im)
        im = bg.convert("RGB")
    fresh = Image.frombytes(im.mode, im.size, im.tobytes())
    dst.parent.mkdir(parents=True, exist_ok=True)
    fresh.save(dst, format="PNG", optimize=True)


def write_ico(parts: list[tuple[int, bytes]], dst: Path) -> None:
    """An ICO holding PNG images, one per size."""
    head = struct.pack("<HHH", 0, 1, len(parts))
    offset = 6 + 16 * len(parts)
    entries, blobs = b"", b""
    for size, data in parts:
        entries += struct.pack(
            "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset
        )
        blobs += data
        offset += len(data)
    dst.write_bytes(head + entries + blobs)


def main() -> None:
    WORK.mkdir(exist_ok=True)
    p = glyph_path()
    vs = variants(p)
    for name, text in vs.items():
        (WORK / f"{name}.svg").write_text(text, encoding="utf-8", newline="")
    (HERE / "countonce-mark.svg").write_text(vs["mark"], encoding="utf-8", newline="")

    jobs, seen = [], set()
    needed = {(v, s) for v, s, _, _ in OUTPUTS} | set(ICO_PARTS) | set(EXTRA)
    for v, s in sorted(needed):
        if (v, s) in seen:
            continue
        seen.add((v, s))
        jobs.append(
            {
                "svg": str(WORK / f"{v}.svg"),
                "size": s,
                "out": str(WORK / f"{v}-{s}.png"),
            }
        )
    (WORK / "jobs.json").write_text(json.dumps(jobs), encoding="utf-8")
    subprocess.run(
        ["node", str(HERE / "render.mjs"), str(WORK / "jobs.json")],
        check=True,
        env=os.environ,
    )

    for v, s, dst, opaque in OUTPUTS:
        clean_png(WORK / f"{v}-{s}.png", dst, opaque)

    ico_parts = []
    for v, s in ICO_PARTS:
        clean_png(WORK / f"{v}-{s}.png", WORK / f"ico-{s}.png", False)
        ico_parts.append((s, (WORK / f"ico-{s}.png").read_bytes()))
    write_ico(ico_parts, ROOT / "public/favicon.ico")

    # The SVG favicon is the 16 px pixel-fitted drawing: every edge sits on a whole pixel at 16 and
    # at 32 (2x screens), the two sizes browsers draw it at in tabs.
    (ROOT / "public/favicon.svg").write_text(vs["s16"], encoding="utf-8", newline="")
    print(
        f"wrote {len(OUTPUTS)} PNGs, favicon.ico ({len(ico_parts)} sizes), favicon.svg"
    )


EXTRA = [
    ("s16", 16),
    ("s32", 32),
    ("mark", 16),
    ("mark", 32),
    ("full", 1024),
    ("fg", 432),
]

if __name__ == "__main__":
    sys.exit(main())
