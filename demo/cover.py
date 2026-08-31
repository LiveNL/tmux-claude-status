#!/usr/bin/env python3
"""Build screenshots/cover.png from demo/cover.tape's recording.

vhs's Screenshot command proved unreliable, so the still is the middle frame
of the short recording, with the title drawn on top.

    vhs demo/cover.tape && python3 demo/cover.py
"""
from PIL import Image, ImageDraw, ImageFont, ImageSequence
from pathlib import Path

RAW = Path(__file__).resolve().parent / ".cover-raw.gif"
PNG = Path(__file__).resolve().parent.parent / "screenshots" / "cover.png"

def font(size, index=1):
    try:
        return ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", size, index=index)
    except OSError:
        return ImageFont.load_default()

def main():
    src = Image.open(RAW)
    frames = list(ImageSequence.Iterator(src))
    im = frames[len(frames) // 2].convert("RGB")
    draw = ImageDraw.Draw(im)
    draw.text((48, 74), "tmux-claude-status-tabs", font=font(44), fill=(230, 237, 237))
    draw.text((50, 136), "every Claude Code session's state, live in your tmux tab bar",
              font=font(21, index=0), fill=(120, 158, 158))
    im.save(PNG)
    print(f"titled {PNG}")

if __name__ == "__main__":
    main()
