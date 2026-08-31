#!/usr/bin/env python3
"""Cut /tmp/claude-demo-minis.gif into one bar-strip GIF per state.

The recording (demo/minis.tape) shows four segments — running, input,
permission, done — separated by one-second idle gaps on the api tab. No clock
maths: each frame is classified by the api tab's colour, and the idle gaps are
the cut points. Output: screenshots/state-<state>.gif, cropped to the bar.

    vhs demo/minis.tape && python3 demo/minis.py
"""
from PIL import Image, ImageSequence
from pathlib import Path

SRC = Path(__file__).resolve().parent / ".minis-raw.gif"
OUT = Path(__file__).resolve().parent.parent / "screenshots"
ORDER = ["running", "input", "permission", "done"]

# The api tab's cell in the bar, and the palette the theme paints it with.
TAB = (120, 205, 310, 250)          # x0, y0, x1, y1
STRIP = (0, 192, 940, 258)          # what ends up in the gifs
COLORS = {
    "teal":  (77, 178, 214),        # running spinner / text  #4db2d6
    "amber": (255, 191, 64),        # input                   #ffbf40
    "red":   (255, 87, 87),         # permission              #ff5757
    "green": (80, 200, 160),        # done                    #50c8a0
}
MIN_DIFF, MIN_FRAMES = 40, 3

# Absolute colour matching breaks on vhs's palette quantisation (the idle gray
# lands inside any reasonable tolerance of the muted green). So classify
# differentially: pixels that differ from the recording's idle first frame are
# the state's ink, and those vote for their nearest anchor colour.
def classify(frame, reference):
    region = frame.crop(TAB).getdata()
    votes = dict.fromkeys(COLORS, 0)
    changed = 0
    for px, ref in zip(region, reference):
        if abs(px[0] - ref[0]) + abs(px[1] - ref[1]) + abs(px[2] - ref[2]) <= 60:
            continue
        changed += 1
        name = min(COLORS, key=lambda n: sum(abs(a - b) for a, b in zip(px, COLORS[n])))
        votes[name] += 1
    if changed < MIN_DIFF:
        return None
    return max(votes, key=lambda n: votes[n])

def main():
    src = Image.open(SRC)
    frames, durations, states = [], [], []
    reference = None
    for frame in ImageSequence.Iterator(src):
        rgb = frame.convert("RGB")
        if reference is None:
            reference = list(rgb.crop(TAB).getdata())
        frames.append(rgb)
        durations.append(frame.info.get("duration", 50))
        states.append(classify(rgb, reference))

    segments, current = [], None
    for i, state in enumerate(states):
        if state is None:
            current = None
        elif current is None:
            current = [i, i]
            segments.append(current)
        else:
            current[1] = i
    segments = [s for s in segments if s[1] - s[0] + 1 >= MIN_FRAMES]
    if len(segments) != len(ORDER):
        raise SystemExit(f"expected {len(ORDER)} segments, found {len(segments)}: {segments}")

    for (start, end), name in zip(segments, ORDER):
        clip = [f.crop(STRIP).quantize(colors=128) for f in frames[start:end + 1]]
        out = OUT / f"state-{name}.gif"
        clip[0].save(out, save_all=True, append_images=clip[1:],
                     duration=durations[start:end + 1], loop=0, optimize=True)
        print(f"{out.name}: frames {start}-{end}")

if __name__ == "__main__":
    main()
