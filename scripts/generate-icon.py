#!/usr/bin/env python3

from pathlib import Path
import math
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"
ICONSET = RESOURCES / "MagicSwitch.iconset"
ICNS = RESOURCES / "MagicSwitch.icns"


def rounded_rectangle(draw, box, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def line(draw, points, fill, width):
    draw.line(points, fill=fill, width=width, joint="curve")


def arrowhead(draw, tip, angle, size, fill):
    left = (
        tip[0] - math.cos(angle - 0.55) * size,
        tip[1] - math.sin(angle - 0.55) * size,
    )
    right = (
        tip[0] - math.cos(angle + 0.55) * size,
        tip[1] - math.sin(angle + 0.55) * size,
    )
    draw.polygon([tip, left, right], fill=fill)


def draw_icon(size):
    scale = 4
    canvas_size = size * scale
    image = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    def s(value):
        return int(round(value * scale))

    bg = (24, 28, 34, 255)
    bg_shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(bg_shadow)
    rounded_rectangle(
        shadow_draw,
        (s(82), s(74), s(942), s(934)),
        s(190),
        fill=(0, 0, 0, 125),
    )
    bg_shadow = bg_shadow.filter(ImageFilter.GaussianBlur(s(18)))
    image.alpha_composite(bg_shadow)

    rounded_rectangle(
        draw,
        (s(78), s(64), s(946), s(922)),
        s(184),
        fill=bg,
        outline=(70, 82, 96, 255),
        width=s(6),
    )

    # Soft top-left highlight.
    rounded_rectangle(
        draw,
        (s(102), s(88), s(922), s(900)),
        s(162),
        outline=(92, 116, 130, 110),
        width=s(3),
    )

    laptop_fill = (34, 40, 48, 255)
    laptop_outline = (171, 193, 204, 255)
    accent_blue = (50, 146, 255, 255)
    accent_mint = (89, 229, 185, 255)

    # Left Mac.
    rounded_rectangle(
        draw,
        (s(170), s(250), s(470), s(470)),
        s(28),
        fill=laptop_fill,
        outline=laptop_outline,
        width=s(12),
    )
    rounded_rectangle(
        draw,
        (s(132), s(482), s(508), s(548)),
        s(20),
        fill=(44, 51, 60, 255),
        outline=laptop_outline,
        width=s(10),
    )
    rounded_rectangle(
        draw,
        (s(252), s(510), s(388), s(524)),
        s(6),
        fill=(93, 111, 124, 255),
    )

    # Right Mac.
    rounded_rectangle(
        draw,
        (s(554), s(250), s(854), s(470)),
        s(28),
        fill=laptop_fill,
        outline=laptop_outline,
        width=s(12),
    )
    rounded_rectangle(
        draw,
        (s(516), s(482), s(892), s(548)),
        s(20),
        fill=(44, 51, 60, 255),
        outline=laptop_outline,
        width=s(10),
    )
    rounded_rectangle(
        draw,
        (s(636), s(510), s(772), s(524)),
        s(6),
        fill=(93, 111, 124, 255),
    )

    # Switch arrows.
    line(draw, [(s(338), s(690)), (s(700), s(690))], accent_blue, s(34))
    arrowhead(draw, (s(726), s(690)), 0, s(56), accent_blue)

    line(draw, [(s(686), s(790)), (s(324), s(790))], accent_mint, s(34))
    arrowhead(draw, (s(298), s(790)), math.pi, s(56), accent_mint)

    # Small Bluetooth-style center mark.
    line(draw, [(s(512), s(610)), (s(512), s(870))], (224, 239, 242, 255), s(18))
    line(draw, [(s(512), s(610)), (s(594), s(692)), (s(512), s(752))], (224, 239, 242, 255), s(18))
    line(draw, [(s(512), s(870)), (s(594), s(788)), (s(512), s(728))], (224, 239, 242, 255), s(18))

    return image.resize((size, size), Image.Resampling.LANCZOS)


def save_iconset():
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)

    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    for pixel_size, name in sizes:
        draw_icon(pixel_size).save(ICONSET / name)


def main():
    RESOURCES.mkdir(parents=True, exist_ok=True)
    save_iconset()
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    shutil.rmtree(ICONSET)
    print(ICNS)


if __name__ == "__main__":
    main()
