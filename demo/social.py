#!/usr/bin/env python3
"""Draw screenshots/social-preview.png (1280x640, GitHub's 2:1 card).

Banner layout: title and tagline left, glyph legend right, the real bar from
demo/.cover-raw.gif as the image's bottom edge. Upload by hand under
repo Settings → Social preview — GitHub has no API for it.

    vhs demo/cover.tape && python3 demo/social.py
"""
from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageSequence
from pathlib import Path

RAW = Path(__file__).resolve().parent / ".cover-raw.gif"
PNG = Path(__file__).resolve().parent.parent / "screenshots" / "social-preview.png"

BG = (11, 21, 23)
FG = (230, 237, 237)
DIM = (120, 158, 158)
TEAL = (77, 178, 214)
AMBER = (255, 191, 64)
RED = (255, 87, 87)
GREEN = (80, 200, 160)

def menlo(size, index=1):
    try:
        return ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", size, index=index)
    except OSError:
        return ImageFont.load_default()

def main():
    W, H = 1280, 640
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)

    d.text((72, 128), "tmux-claude-status-tabs", font=menlo(54), fill=FG)
    d.text((75, 216), "every Claude Code session's state,", font=menlo(26, index=0), fill=DIM)
    d.text((75, 254), "live in your tmux tab bar", font=menlo(26, index=0), fill=DIM)

    rows = [("hex", TEAL, "working"), ("?", AMBER, "waiting on you"),
            ("!", RED, "needs permission"), ("✓", GREEN, "done")]
    f_g, f_t = menlo(32), menlo(27)
    x_g, x_t, y = 812, 868, 122
    for glyph, col, label in rows:
        if glyph == "hex":
            d.regular_polygon((x_g + 16, y + 20, 17), 6, rotation=90, fill=col)
        else:
            d.text((x_g, y), glyph, font=f_g, fill=col)
        d.text((x_t, y + 4), label, font=f_t, fill=col)
        y += 82

    src = Image.open(RAW)
    frames = list(ImageSequence.Iterator(src))
    strip = frames[len(frames) // 2].convert("RGB").crop((0, 196, 1250, 258))
    strip = ImageEnhance.Color(strip).enhance(1.15)
    sh = int(strip.height * W / strip.width * 1.35)
    im.paste(strip.resize((W, sh), Image.LANCZOS), (0, H - sh))
    d.rectangle((0, H - sh - 3, W, H - sh), fill=(45, 66, 68))

    im.save(PNG)
    print(f"drew {PNG}")

if __name__ == "__main__":
    main()
