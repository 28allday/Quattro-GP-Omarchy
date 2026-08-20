#!/usr/bin/env python3
"""Clear third-party marks from the tracked mood board.

`reference/moodboard.png` is kept in the repo because every crop box in
`make_art.py` is meaningless without it -- but as generated it carried a
title block reading POLE POSITION / CLONE / AUDI QUATTRO, set in the
original arcade logo's lettering, plus Audi four-ring devices and Audi
wordmarks on several car views.

None of that is ours to ship. This clears those regions *in place*, at the
board's original 1536x1024, so every crop box in `make_art.py` keeps its
coordinates and the sprites regenerate byte-identical from a fresh clone.
Cropping the board would have shifted every box; blanking does not.

Most regions below fall outside every crop box in `make_art.py`, so they
never reached a sprite. The exception is the "Audi quattro" wordmark on the
three rear-view player cars' boot lids, which sits *inside* the crop boxes:
that one is handled in BOTH places. The board heals it (the 2026-08-20
copyright pass -- before that the board still carried it, which made the
README's "no marks appear here" untrue of the repo itself), and the `scrub`
rects in `make_art.py` still overwrite the same rows on the shipped sprite,
so a heal artefact can never reach the output either.

Three ways of clearing, because the marks sit on three kinds of surface:

  clear   flat fill with the board's background. For the title block,
          which sits on empty board.
  heal-v  interpolate each column between the rows above and below the
          rect. For badges on bodywork crossed by *vertical* features --
          the rally cars' door line, the top-down cars' bonnet stripes --
          which the interpolation carries straight through the gap.
  heal-h  interpolate each row between the columns left and right of the
          rect. For the wordmark on the mockup car's boot-lid strip,
          which is bounded above and below by black and so has nothing
          useful to interpolate vertically.

Idempotent: re-running on an already-cleared board changes nothing, since
healed pixels are themselves the interpolation of their own neighbours.

    python3 art/scrub_board.py
"""

from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
BOARD = HERE / "reference" / "moodboard.png"

# The board's modal background, so cleared areas read as empty board rather
# than as a black rectangle pasted over it.
BACKGROUND = (2, 6, 9)

# How many rows/columns either side of a rect to average when sampling the
# surface to heal from. More than one, so a single noisy pixel cannot smear
# itself down the whole repair.
SAMPLE = 3

# The five top-down cars are evenly spaced; both badges share the car's
# centre line, so the rects are generated rather than written out five times.
TOPDOWN_CENTRES = (76, 199, 319, 440, 561)

# (x0, y0, x1, y1, how, why)
REGIONS = [
    (0, 0, 600, 244, "clear",
     "title block: POLE POSITION logo, CLONE, AUDI QUATTRO"),

    (110, 399, 148, 423, "heal-v", "four-ring device, side-view rally car 1"),
    (393, 399, 431, 423, "heal-v", "four-ring device, side-view rally car 2"),

    (1116, 341, 1249, 350, "heal-h",
     "'Audi quattro' wordmark on the mockup car's boot lid"),

    # The three rear-view player cars. The wordmark sits on the light boot
    # strip (strip spans x 46..160 / 226..341 / 407..522 at y=271, measured),
    # so each rect stops SAMPLE columns short of the strip's ends and the
    # heal interpolates along the strip itself. These are the only regions
    # inside crop boxes; make_art.py's scrub rects overwrite the same rows
    # on the output, so the sprite never depends on this heal being perfect.
    (52,  270, 155, 283, "heal-h", "'Audi quattro' wordmark, rear view 1"),
    (232, 270, 335, 283, "heal-h", "'Audi quattro' wordmark, rear view 2"),
    (413, 270, 516, 283, "heal-h", "'Audi quattro' wordmark, rear view 3"),
]

REGIONS += [
    (c - 20, 499, c + 20, 512, "heal-v", f"four-ring device, top-down car {i}")
    for i, c in enumerate(TOPDOWN_CENTRES, 1)
]
REGIONS += [
    (c - 22, 648, c + 22, 671, "heal-v", f"'Audi' oval, top-down car {i}")
    for i, c in enumerate(TOPDOWN_CENTRES, 1)
]


def _mean(px, points):
    """Average colour of some pixels, as ints."""
    n = len(points)
    totals = [0, 0, 0]
    for x, y in points:
        for i, v in enumerate(px[x, y]):
            totals[i] += v
    return [t / n for t in totals]


def _blend(a, b, t):
    return tuple(int(round(p + (q - p) * t)) for p, q in zip(a, b))


def heal_vertical(px, x0, y0, x1, y1):
    """Rebuild the rect by interpolating each column top-to-bottom."""
    for x in range(x0, x1):
        top = _mean(px, [(x, y0 - 1 - k) for k in range(SAMPLE)])
        bottom = _mean(px, [(x, y1 + k) for k in range(SAMPLE)])
        for y in range(y0, y1):
            px[x, y] = _blend(top, bottom, (y - y0 + 1) / (y1 - y0 + 1))


def heal_horizontal(px, x0, y0, x1, y1):
    """Rebuild the rect by interpolating each row left-to-right."""
    for y in range(y0, y1):
        left = _mean(px, [(x0 - 1 - k, y) for k in range(SAMPLE)])
        right = _mean(px, [(x1 + k, y) for k in range(SAMPLE)])
        for x in range(x0, x1):
            px[x, y] = _blend(left, right, (x - x0 + 1) / (x1 - x0 + 1))


def scrub(path=BOARD, regions=REGIONS):
    board = Image.open(path).convert("RGB")
    px = board.load()
    for x0, y0, x1, y1, how, _why in regions:
        if how == "clear":
            board.paste(BACKGROUND, (x0, y0, x1, y1))
        elif how == "heal-v":
            heal_vertical(px, x0, y0, x1, y1)
        elif how == "heal-h":
            heal_horizontal(px, x0, y0, x1, y1)
        else:
            raise ValueError(f"unknown method {how!r}")
    board.save(path)
    return board.size


if __name__ == "__main__":
    size = scrub()
    print(f"cleared {len(REGIONS)} regions from {BOARD.name} ({size[0]}x{size[1]})")
    for x0, y0, x1, y1, how, why in REGIONS:
        print(f"  {how:7} ({x0:4}, {y0:4}, {x1:4}, {y1:4})  {why}")
