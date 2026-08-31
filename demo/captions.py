#!/usr/bin/env python3
"""Overlay the demo captions onto screenshots/demo.gif, top-right, in red.

Runs after vhs: the captions are drawn on the finished frames so they are
unmistakably annotation, not terminal content. Caption windows are in driver
seconds (they mirror the tick numbers in drive.sh); the offset to visible
recording time is measured off the first permission-red frame, not guessed.

    vhs demo/demo.tape && python3 demo/captions.py
"""
from PIL import Image, ImageDraw, ImageFont, ImageSequence
from pathlib import Path

GIF = Path(__file__).resolve().parent.parent / "screenshots" / "demo.gif"
RED = (255, 87, 87) # #ff5757, the permission red
MARGIN_X, MARGIN_Y = 22, 10
TAB = (120, 205, 310, 250)  # the api tab's cell in the bar
RED_AT = 4.0                # the driver paints it red at tick 8

# (driver_start_s, driver_end_s, text) — starts mirror drive.sh ticks / 2.
CAPTIONS = [
    (0.5,  4.0, "'1. api' and '2. frontend' are working"),
    (4.0,  6.0, "'1. api' turns red — it needs an approval"),
    (6.0,  8.0, "you switch to '1. api', press 1"),
    (8.0, 10.0, "approved — '1. api' runs on"),
    (10.0, 12.0, "back to '4. notes'"),
    (12.0, 15.0, "'2. frontend' finishes: ✓"),
    (15.0, 18.0, "'3. infra' asks a question: ?"),
    (18.0, 99.0, "'1. api' finishes: ✓"),
]

def load_font():
    for path in (
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    ):
        try:
            return ImageFont.truetype(path, 28, index=1)  # index 1: Menlo Bold
        except OSError:
            try:
                return ImageFont.truetype(path, 28)
            except OSError:
                continue
    return ImageFont.load_default()

def caption_at(t, lead):
    for start, end, text in CAPTIONS:
        if start - lead <= t < end - lead:
            return text
    return None

def find_lead(src):
    """No clock guessing: the first frame whose api tab holds permission-red
    pixels is driver second RED_AT, and every caption window shifts by that."""
    elapsed = 0.0
    for frame in ImageSequence.Iterator(src):
        region = frame.convert("RGB").crop(TAB)
        hits = sum(
            1 for r, g, b in region.getdata()
            if abs(r - RED[0]) <= 30 and abs(g - RED[1]) <= 30 and abs(b - RED[2]) <= 30
        )
        if hits >= 12:
            return RED_AT - elapsed
        elapsed += frame.info.get("duration", 50) / 1000.0
    raise SystemExit("no permission-red frame found; is this the workflow gif?")

def main():
    src = Image.open(GIF)
    lead = find_lead(src)
    src.seek(0)
    print(f"calibrated lead: {lead:.2f}s")
    font = load_font()
    frames, durations = [], []
    elapsed = 0.0
    for frame in ImageSequence.Iterator(src):
        duration = frame.info.get("duration", 50)
        rgb = frame.convert("RGB")
        text = caption_at(elapsed, lead)
        if text:
            draw = ImageDraw.Draw(rgb)
            w = draw.textlength(text, font=font)
            draw.text((rgb.width - w - MARGIN_X, MARGIN_Y), text, font=font, fill=RED)
        frames.append(rgb.quantize(colors=128))
        durations.append(duration)
        elapsed += duration / 1000.0
    frames[0].save(
        GIF, save_all=True, append_images=frames[1:],
        duration=durations, loop=0, optimize=True,
    )
    print(f"captioned {len(frames)} frames -> {GIF}")

if __name__ == "__main__":
    main()
