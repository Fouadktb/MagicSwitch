#!/usr/bin/env python3

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "dmg-background.png"


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)

    image = Image.new("RGBA", (720, 440), (239, 243, 247, 255))
    draw = ImageDraw.Draw(image)

    title_font = font("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 28)
    body_font = font("/System/Library/Fonts/Supplemental/Arial.ttf", 16)
    small_font = font("/System/Library/Fonts/Supplemental/Arial.ttf", 13)

    # Simple curved drag arrow. The real app icon and Applications alias are
    # Finder items laid out on top of this background.
    draw.rounded_rectangle((24, 22, 696, 418), radius=22, fill=(250, 252, 255, 255), outline=(203, 213, 225, 255), width=2)

    points = []
    start = (258, 224)
    control = (360, 178)
    end = (448, 224)
    for index in range(36):
        t = index / 35
        x = (1 - t) * (1 - t) * start[0] + 2 * (1 - t) * t * control[0] + t * t * end[0]
        y = (1 - t) * (1 - t) * start[1] + 2 * (1 - t) * t * control[1] + t * t * end[1]
        points.append((x, y))
    draw.line(points, fill=(34, 126, 238, 255), width=12, joint="curve")

    draw.polygon([(492, 224), (446, 198), (456, 250)], fill=(34, 126, 238, 255))

    draw.text((360, 54), "Install MagicSwitch", fill=(30, 38, 48, 255), font=title_font, anchor="mm")
    draw.text((360, 350), "Drag MagicSwitch.app to Applications", fill=(30, 38, 48, 255), font=body_font, anchor="mm")
    draw.text((360, 376), "Then open it from Applications on each Mac.", fill=(86, 101, 116, 255), font=small_font, anchor="mm")

    image.save(OUT)
    print(OUT)


if __name__ == "__main__":
    main()
