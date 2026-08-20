#!/usr/bin/env python3
"""Build the Quattro GP sprite set from the approved mood board.

The mood board (art/reference/moodboard.png) is a 1536x1024 render *of* pixel
art -- ~188k unique colours, no clean pixel grid -- so it cannot be used as-is.
This turns it into real pixel art:

    crop -> cut the background to alpha -> trim to content -> box-downsample to
    the native grid -> quantise to a flat palette -> hard alpha

Box-downsampling does the real work: averaging each ~2x block down to one pixel
is exactly the filter that removes the render's noise and dithering while
keeping the silhouette. Quantising afterwards snaps the result onto a flat
palette, so the sprites read as sprites rather than as tiny photographs.

Three background modes, because the board has more than one kind of backdrop:
  "dark"  flood-fill the near-black board backdrop from the crop border.
          Flood-filling rather than colour-keying is what keeps a car's own
          black areas (windows, tyres, shadow) opaque.
  "seed"  flood-fill from the border matching each border pixel's own colour.
  "key"   key out sky and grass by measured colour rules. The scenery needs
          this rather than "seed": a tolerance wide enough to clear the grass
          also swallows the tree's brightest foliage and hollows the canopy.

Sizes are auto-fitted: the trimmed artwork is scaled to fit its native box
preserving aspect, then bottom-centred, so every roadside sprite stands on its
own baseline and can be placed by its foot.

This file -- not the PNGs -- is the source of truth for the art. Re-run after
editing any box:

    python3 art/make_art.py

Outputs art/sprites/*.png, art/backdrop.png and art/palette.json.
"""

import json
import math
import random
import os
from collections import deque

from PIL import Image, ImageDraw, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
BOARD = os.path.join(HERE, "reference", "moodboard.png")
OUT = os.path.join(HERE, "sprites")

# Every native size is in *game* pixels: the game renders at 320x240 and is
# integer-scaled up. The player car is 72px: what has to match the arcade is
# the car's share of the ROAD at its own row (~28%), not of the screen -- the
# original 88px was calibrated against screen width, which made the car ~38%
# of the tarmac it was sitting on.
#
# `scrub` rects are (x0, y0, x1, y1, src_y) in native pixels, applied after the
# downsample. They take the Audi wordmark off the boot lid: it is an illegible
# smear by 88px wide, but this repo should not carry someone else's marks at
# any resolution.
SPRITES = [
    # name            crop box                  native    cols  bg      scrub
    ("car_straight",  (24, 244, 186, 334),      (72, 40), 20, "dark", [(3, 13, 69, 17, 12)]),
    ("car_left",      (211, 244, 358, 334),     (72, 40), 20, "dark", [(3, 13, 69, 17, 12)]),
    ("car_right",     (393, 244, 539, 334),     (72, 40), 20, "dark", [(3, 13, 69, 17, 12)]),

    ("rival_red",     (24, 770, 127, 850),      (56, 40), 14, "dark", []),
    ("rival_blue",    (147, 770, 252, 850),     (56, 40), 14, "dark", []),
    ("rival_yellow",  (276, 770, 379, 850),     (56, 40), 14, "dark", []),
    ("rival_green",   (401, 770, 503, 850),     (56, 40), 14, "dark", []),
    ("rival_white",   (526, 770, 627, 850),     (56, 40), 14, "dark", []),

    ("sign_right",    (666, 774, 740, 857),     (28, 32), 10, "dark", []),
    ("sign_left",     (754, 774, 819, 857),     (28, 32), 10, "dark", []),
    ("sign_100",      (833, 788, 901, 857),     (26, 26),  8, "dark", []),
    ("sign_50",       (913, 788, 965, 857),     (26, 26),  8, "dark", []),
    ("sign_checker",  (982, 792, 1036, 857),    (26, 28),  8, "dark", []),
    ("cone_a",        (1058, 785, 1083, 850),   (10, 26),  6, "dark", []),
    ("cone_b",        (1095, 784, 1120, 850),   (10, 26),  6, "dark", []),
    ("marshal",       (1165, 753, 1263, 872),   (40, 48), 14, "dark", []),

    ("tree_big",      (667, 564, 713, 608),     (30, 30), 10, "key", []),
    ("tree_small",    (725, 574, 752, 606),     (18, 20),  8, "key", []),
]

# The panorama drawn behind the road. Cropped sky-through-mountain-base so its
# bottom edge is the horizon line: it needs no alpha, it is simply blitted with
# its bottom on the horizon and plain sky filled in above.
BACKDROP = ((990, 498, 1502, 586), (256, 44), 24)

# The other three courses' horizons, cut from the mood board's own background
# tiles -- which is what those tiles were put there for.
#
# Unlike BACKDROP these are not a straight crop-and-shrink, because the tiles
# are small, squarish scenes rather than a wide panorama:
#
#   band      the rows of the tile that are actually horizon. The sky above
#             the band comes from the course's `sky` colour, exactly as it
#             does for Fuji, so the strip only has to carry the silhouette.
#   height    the band is scaled to this many rows and the width follows,
#             preserving aspect. Sunset gets a taller band because its sky
#             is a gradient the flat `sky` uniform cannot reproduce.
#   sun       optional box, painted out with the sky colour sampled from the
#             same row. A backdrop tiles, and a tiling sun is two suns --
#             which is also why Sunset does not use this path at all; it is
#             drawn instead, see SUNSET below.
#
# Every strip is mirrored before it is written, which makes it seamless at the
# wrap and doubles its width -- so it repeats about 1.3x across the screen
# rather than 3x, and there is no visible join to catch the eye.
BACKDROPS = {
    "backdrop_seaside": {
        "box": (894, 622, 1055, 706), "band": (20, 78), "height": 44,
        "colours": 24, "sun": None,
    },
    "backdrop_city": {
        "box": (1216, 622, 1359, 706), "band": (24, 82), "height": 44,
        "colours": 24, "sun": None,
    },
}

BOARD_BG = (13, 13, 13)
BOARD_TOL = 38


def flood(img, seeds, match):
    """Set every pixel reachable from `seeds` for which match(px, seed) holds to alpha 0."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    seen = [[False] * h for _ in range(w)]
    q = deque()
    for sx, sy, ref in seeds:
        if 0 <= sx < w and 0 <= sy < h and not seen[sx][sy] and match(px[sx, sy], ref):
            seen[sx][sy] = True
            q.append((sx, sy, ref))
    while q:
        x, y, ref = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[nx][ny] and match(px[nx, ny], ref):
                seen[nx][ny] = True
                q.append((nx, ny, ref))
    return img


def cut_dark(img):
    w, h = img.size
    seeds = [(x, y, BOARD_BG) for x in range(w) for y in (0, h - 1)]
    seeds += [(x, y, BOARD_BG) for y in range(h) for x in (0, w - 1)]

    def match(p, ref):
        return p[3] != 0 and all(abs(p[i] - ref[i]) <= BOARD_TOL for i in range(3))

    return flood(img, seeds, match)


def fill_holes(img, src):
    """Give back the body pixels the background flood ate.

    cut_dark only removes what is *reachable* from the crop border, but the
    board's drop shadows sit within tolerance of the backdrop, so the flood
    can crawl under a car and up into its own dark trim -- worst on the white
    rival, whose grey shading is the closest of the five to the board. The
    road then shows through the car in play.

    A car's rear view has no genuine see-through gaps, so a transparent pixel
    with opaque pixels somewhere above, below, left AND right of it is a bite
    out of the body, not background; it gets its original crop colour back.
    Run to a fixed point: refilling a bite can enclose its neighbour.
    """
    img = img.convert("RGBA")
    w, h = img.size
    px, sp = img.load(), src.convert("RGBA").load()
    changed = True
    while changed:
        changed = False
        for y in range(h):
            for x in range(w):
                if px[x, y][3] != 0:
                    continue
                if (any(px[i, y][3] for i in range(x)) and
                        any(px[i, y][3] for i in range(x + 1, w)) and
                        any(px[x, j][3] for j in range(y)) and
                        any(px[x, j][3] for j in range(y + 1, h))):
                    px[x, y] = sp[x, y][:3] + (255,)
                    changed = True
    return img


def cut_seed(img, tol=52):
    """Carve out flat sky/grass by flooding from each border pixel's own colour."""
    rgb = img.convert("RGB")
    w, h = img.size
    src = rgb.load()
    seeds = [(x, y, src[x, y]) for x in range(w) for y in (0, h - 1)]
    seeds += [(x, y, src[x, y]) for y in range(h) for x in (0, w - 1)]

    def match(p, ref):
        return p[3] != 0 and sum(abs(p[i] - ref[i]) for i in range(3)) <= tol

    return flood(img, seeds, match)


def cut_key(img):
    """Key out flat sky and flat grass by measured colour rules.

    The scenery sits on sky above and grass below, and a tolerance flood is the
    wrong tool: the tree's brightest foliage highlights (#147319) are close
    enough to grass (#348e15) to be swallowed, which hollows the canopy out.
    These two rules were read off the crop instead -- the grass test needs
    g >= 128, which the highlights (g = 115) sit safely under.
    """
    img = img.convert("RGBA")
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, _ = px[x, y]
            grass = g >= 128 and g > r + 45 and g > b + 55
            sky = b >= 140 and b > r + 40
            if grass or sky:
                px[x, y] = (0, 0, 0, 0)
    return img


def trim(img):
    bb = img.getbbox()
    return img.crop(bb) if bb else img


def apply_scrub(img, rects):
    """Overpaint (x0, y0, x1, y1, src_y) rects, in *native* pixels.

    Native pixels, not fractions of the crop: the three player-car crops differ
    by a couple of source rows each, and a fractional rect that is correct on
    one of them slides into the rear window on the next. Every column is filled
    from row `src_y`, so the band keeps the boot lid's own shading instead of
    becoming a flat bar.
    """
    if not rects:
        return img
    px = img.load()
    w, h = img.size
    for x0, y0, x1, y1, src_y in rects:
        for x in range(max(0, x0), min(w, x1)):
            ref = px[x, min(h - 1, src_y)]
            if ref[3] == 0:
                continue
            for y in range(max(0, y0), min(h, y1)):
                if px[x, y][3] != 0:
                    px[x, y] = ref
    return img


def fit(img, native):
    """Scale to fit the native box preserving aspect, then bottom-centre it."""
    tw, th = native
    s = min(tw / img.width, th / img.height)
    nw, nh = max(1, round(img.width * s)), max(1, round(img.height * s))
    small = img.resize((nw, nh), Image.BOX)
    out = Image.new("RGBA", native, (0, 0, 0, 0))
    out.paste(small, ((tw - nw) // 2, th - nh), small)
    return out


def quantise(img, colours):
    rgb = Image.new("RGB", img.size, (0, 0, 0))
    rgb.paste(img, (0, 0), img)
    q = rgb.quantize(colors=colours, method=Image.MEDIANCUT, dither=Image.NONE)
    q = q.convert("RGB").convert("RGBA")
    src, dst = img.load(), q.load()
    for y in range(img.height):
        for x in range(img.width):
            dst[x, y] = dst[x, y][:3] + (255 if src[x, y][3] >= 128 else 0,)
    return q


# ----------------------------------------------------------------- sunset
#
# Sunset is the one course whose horizon is drawn rather than cut from the
# mood board. A tile could not carry it: the look wanted is a huge low sun
# banded by cloud, sitting behind layered ridges under a graded sky, and a
# strip that tiles can hold none of those three things. A tiling sun is two
# suns; a flat `sky` uniform cannot be a gradient; and ridges want authoring
# rather than resampling from an 84px tile.
#
# So it is generated here in three pieces that Road.qml layers:
#
#   sky      a vertical gradient, from SUNSET_SKY
#   sun      ONE sprite, parallaxed but never tiled, drawn behind the ridges
#   strip    clouds and three ridge layers, tiling and mirrored, drawn over
#            the sun so it sets behind them
#
# The colours are sampled values from a reference image, recorded here as
# numbers. No part of that image is redistributed: everything below is drawn
# from these ten values and nothing else, which is also why it comes out as
# clean pixel art rather than a resampled photograph.
SUNSET_SKY = [           # (position down the sky, colour)
    (0.00, "#b93a7f"),   # magenta overhead
    (0.35, "#cc407d"),
    (0.72, "#ef706a"),   # salmon
    (1.00, "#ee8a68"),   # orange at the horizon
]
SUNSET_SUN    = "#f2ef88"
SUNSET_CLOUD  = ("#ec5f6f", "#ef826b")
SUNSET_RIDGES = ("#d83b74", "#ad2f6d", "#7e2560")   # far, mid, near

SUNSET_STRIP = (160, 64)     # half-width; mirrored to 320
SUNSET_SUN_D = 52


# ---------------------------------------------------------------- the gantry
#
# The sponsor arch over the road. Drawn rather than cut, like the sunset sun:
# there is no gantry on the mood board, and there could not be -- the board is
# a set of views along the road, and an arch is the one piece of furniture that
# spans it.
#
# Sized against the road rather than by eye. The road is 2*ROAD_HALF = 2000
# world units wide and the sprite scale is 13 units per art pixel, so the road
# is 154 art pixels across; the legs sit at +/-96px, which is 1.25 road
# half-widths -- out past the kerb, standing in the verge.
#
# The height is the load-bearing number. The camera eye is CAM_HEIGHT = 1500
# units up, so anything shorter than that is drawn entirely BELOW the horizon
# and reads as a hoarding rather than something you drive under. 120px is 1560
# units: just tall enough that the banner crosses the horizon line and the arch
# passes overhead.
GANTRY = (208, 120)
GANTRY_LOGO_SCALE = 2        # logo pixels per art pixel

GANTRY_BANNER = "#1a1b26"    # the wordmark's own background
GANTRY_INK    = "#9ece6a"    # ...and its own green
GANTRY_EDGE   = "#eeeeeb"    # the lane white, for the banner's border
GANTRY_STEEL  = ("#9aa1a9", "#5c626a", "#7d848c")   # face, shaded edge, beam

# The Omarchy wordmark, 81x19, traced from the official logo.
#
# Traced rather than font-set. The banner first carried "OMARCHY" set in the
# game's own 5x7 HUD font, which was legible and was not the logo: this is a
# drawn mark with bevelled corners, a spike over the M and a descender on the
# R, and none of that survives being spelled out in a generic face.
#
# The trace was fitted rather than eyeballed -- the source is a 1338x336
# upscale, so the block grid (14.877px) was solved for by minimising the
# difference between the trace painted back at source scale and the source
# itself. It round-trips to within the upscale's own soft edges.
#
# Kept as text here, not as a PNG, for the same reason the font is: this file
# is the source of truth for the art, and a bitmap in a screenshots folder is
# not a source. See art/CREDITS.md for the mark's provenance.
OMARCHY_LOGO = [
    ".................###.............................................................",
    "..#####......###########......#######....#######....#######....#...#......#...#..",
    ".#######....#############....########...########...########...##...##....##...##.",
    "###...###..###...###...###..###...###..###...###..###...###..###...###..###...###",
    "###...###..###...###...###..###...###..###...###..###...###..###...###..###...###",
    "###...###..###...###...###..###...###..###...###..###...##...###...###..###...###",
    "###...###..###...###...###..###...###..###...###..###...#....###...###..###...###",
    "###...###..###...###...###..###...###..###...###..###........###...###..###...###",
    "###...###..###...###...###.##########.#########...###.......###########.#########",
    "###...###..###...###...###.##########.########....###......###########..#########",
    "###...###..###...###...###..###...###..###........###........###...###........###",
    "###...###..###...###...###..###...###.##########..###...#....###...###...##...###",
    "###...###..###...###...###..###...###.##########..###...##...###...###..###...###",
    "###...###..###...###...###..###...###..###...###..###...###..###...###..###...###",
    "###...###..###...###...###..###...###..###...###..###...###..###...###..###...###",
    ".#######....##...###...##...###...##...###...###..########...###...##....#######.",
    "..#####......#...###...#....###...#....###...###..#######....###...#......#####..",
    ".......................................###...##..................................",
    ".......................................###...#..................................."
]


# ---------------------------------------------------------- the finish arch
#
# The arch over the start/finish line is the same structure carrying a
# different banner: FINISH, set in the game's own HUD font, between two
# chequered strips. The other two arches a lap are the sponsor board.
#
# Set in the font rather than drawn, which is the opposite call to the Omarchy
# wordmark on the sponsor banner -- and right for the opposite reason. A logo
# is a specific drawn thing and has to be reproduced; "FINISH" is a word on a
# race board, and the font it should be in is the one the rest of the cabinet
# already speaks in.
FINISH_TEXT  = "FINISH"
FINISH_SCALE = 5
FINISH_INK   = "#eeeeeb"     # the lane white, not the sponsor's green


# --------------------------------------------------------- seaside horizon
#
# Drawn rather than cut, for the same reason Sunset's is: what this circuit
# needs is open water meeting the sky with a few headlands standing out of it,
# and the board's coastal tile is a green field with mountains behind it. That
# was fine while Seaside was a green field; the moment the foreground became
# water, a solid band of grass along the horizon was the one thing saying it
# was not the sea.
#
# The profiles are summed sines at INTEGER frequencies across the strip's own
# width, which is what makes it tile without a seam -- the old cut strip has a
# visible join, and three of these are laid side by side.
SEASIDE_STRIP  = (244, 44)
SEASIDE_WATER  = "#8fc0e0"      # distant water, the same value as the fog
SEASIDE_RIDGES = ("#a9c3d4", "#8aa7ba", "#6d8f95")   # far, mid, near


def _rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def _ridge_profile(x, base, amp, phases):
    """Three summed sines: rolling hills that never repeat inside the strip."""
    a, b, c = phases
    v = (math.sin(x / 47.0 + a) * 0.55
         + math.sin(x / 23.0 + b) * 0.30
         + math.sin(x / 11.0 + c) * 0.15)
    return base - v * amp


def make_sunset_strip():
    w, h = SUNSET_STRIP
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Seeded, so the art is identical on every machine and every run. The
    # PNGs are committed, and a regenerate that churned them would make every
    # later art change unreviewable.
    r = random.Random(7)

    # Cloud streaks. Horizontal by nature, so they tile without reading as a
    # repeat, unlike anything with a recognisable shape.
    for _ in range(26):
        y = r.randint(0, int(h * 0.55))
        x = r.randint(-10, w)
        length = r.randint(6, 34)
        colour = _rgb(SUNSET_CLOUD[0] if r.random() < 0.6 else SUNSET_CLOUD[1])
        d.line([(x, y), (x + length, y)], fill=colour + (255,), width=1)

    # Three ridge layers, far to near, each darker and lower in amplitude --
    # which is what reads as distance without any fog.
    for i, (base, amp, seed) in enumerate(((h * 0.48, 12, 11),
                                           (h * 0.66, 10, 23),
                                           (h * 0.84, 8, 41))):
        rr = random.Random(seed)
        phases = [rr.uniform(0, math.pi * 2) for _ in range(3)]
        pts = [(x, _ridge_profile(x, base, amp, phases)) for x in range(w + 1)]
        d.polygon(pts + [(w, h), (0, h)], fill=_rgb(SUNSET_RIDGES[i]) + (255,))

    out = Image.new("RGBA", (w * 2, h))
    out.paste(img, (0, 0))
    out.paste(ImageOps.mirror(img), (w, 0))
    return out


def make_sunset_sun():
    """A low sun, banded by cloud across its lower two thirds.

    The bands are cut to full transparency rather than painted, so the sky
    gradient shows through them exactly as it does either side of the disc.
    They tighten and thicken toward the bottom, which is what makes the sun
    read as sinking into haze rather than as a striped circle.
    """
    dia = SUNSET_SUN_D
    img = Image.new("RGBA", (dia, dia), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, dia - 1, dia - 1], fill=_rgb(SUNSET_SUN) + (255,))

    y, gap, thick = dia * 0.34, 6.0, 1.0
    while y < dia:
        d.rectangle([0, int(y), dia - 1, int(y + thick) - 1], fill=(0, 0, 0, 0))
        y += gap + thick
        gap = max(1.6, gap * 0.80)
        thick = min(4.0, thick * 1.32)
    return img




def _stamp_logo(img, rows, x0, y0, scale, colour):
    """Blit a text-defined bitmap at a whole-number scale.

    Whole numbers only. The gantry is drawn once and then resampled by the
    perspective to whatever size the distance asks for, and a mark that starts
    off the pixel grid never gets back onto it.
    """
    px = img.load()
    for r, line in enumerate(rows):
        for c, bit in enumerate(line):
            if bit != "#":
                continue
            for dy in range(scale):
                for dx in range(scale):
                    px[x0 + c * scale + dx, y0 + r * scale + dy] = colour + (255,)


def _gantry_frame():
    """The arch itself: two legs, a beam, and an empty banner panel.

    Shared by both arches, because they ARE the same structure -- the finish
    line's is not a different gantry, it is the same gantry with a different
    board on it. Returns the image and the banner's height so the caller can
    put something in it.

    Deliberately the darkest thing in the frame apart from the HUD, and for
    the same reason: every course puts this against that course's sky, and a
    dark panel is the only fill that reads on all four -- Fuji's blue, City's
    smog and Sunset's magenta included.
    """
    w, h = GANTRY
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    banner_h = 46
    beam_y = banner_h + 1
    beam_h = 4
    leg_top = beam_y + beam_h
    leg_w = 7
    leg_x = (8, w - 8 - leg_w)          # centres land at +/-96 from the middle

    face, shade, beam = (_rgb(c) for c in GANTRY_STEEL)

    # Legs first, so the banner overlaps them rather than the other way round.
    for lx in leg_x:
        d.rectangle([lx, leg_top, lx + leg_w - 1, h - 1], fill=face + (255,))
        d.rectangle([lx + leg_w - 2, leg_top, lx + leg_w - 1, h - 1],
                    fill=shade + (255,))
        # Base plate. Two rows, a little wider than the leg -- the whole of
        # the foot's job is to say "this is standing on the ground", and at
        # any distance worth seeing it is about three pixels tall.
        d.rectangle([lx - 3, h - 3, lx + leg_w + 2, h - 1], fill=shade + (255,))

    # The beam the banner hangs from, spanning leg to leg.
    d.rectangle([leg_x[0], beam_y, leg_x[1] + leg_w - 1, beam_y + beam_h - 1],
                fill=beam + (255,))

    # Banner: a dark panel with a white border, so it does not dissolve into
    # the horizon haze at the far end of a straight.
    d.rectangle([0, 0, w - 1, banner_h - 1], fill=_rgb(GANTRY_BANNER) + (255,))
    d.rectangle([0, 0, w - 1, banner_h - 1], outline=_rgb(GANTRY_EDGE) + (255,))
    return img, banner_h


def make_gantry():
    """The sponsor arch: the Omarchy wordmark on the banner.

    The wordmark keeps its own background and its own green rather than being
    recoloured per course, because a logo that changes colour is not a logo.
    """
    img, banner_h = _gantry_frame()
    w = img.width

    sc = GANTRY_LOGO_SCALE
    lw = len(OMARCHY_LOGO[0]) * sc
    # Centred on the wordmark's BODY, not on its bounding box: the R's
    # descender is two rows of one letter and centring on it hangs the whole
    # mark a pixel high.
    body = len(OMARCHY_LOGO) - 2
    _stamp_logo(img, OMARCHY_LOGO,
                (w - lw) // 2, (banner_h - body * sc) // 2,
                sc, _rgb(GANTRY_INK))
    return img


def make_gantry_finish():
    """The arch over the start/finish line: FINISH between two chequered
    strips.

    The chequers are the road's own, lifted onto the board -- the line under
    this arch is painted in exactly the same two-deep pattern by the road
    shader, so the banner and the tarmac say the same thing twice, which is
    what makes the arch read as belonging to the line rather than standing
    near it.
    """
    img, banner_h = _gantry_frame()
    d = ImageDraw.Draw(img)
    w = img.width

    # Chequers, one cell deep, along the top and bottom of the panel inside
    # its border. Cell size divides the inner width exactly so the strip never
    # ends on a half square.
    cell = 4
    n = (w - 2) // cell
    x0 = (w - n * cell) // 2          # centred, so the run never ends short
    white = _rgb(GANTRY_EDGE) + (255,)
    for sy in (1, banner_h - 1 - cell):
        for c in range(n):
            if c % 2 == 0:
                d.rectangle([x0 + c * cell, sy, x0 + (c + 1) * cell - 1, sy + cell - 1],
                            fill=white)

    rows = _font_rows(FINISH_TEXT)
    sc = FINISH_SCALE
    tw, th = len(rows[0]) * sc, len(rows) * sc
    _stamp_logo(img, rows, (w - tw) // 2, (banner_h - th) // 2,
                sc, _rgb(FINISH_INK))
    return img



def _font_rows(text):
    """Turn a string into '#'/'.' rows using the game's own 5x7 HUD font.

    Imported from make_font rather than sampled out of font.png, so the road
    lettering and the HUD can never drift apart.
    """
    from make_font import G

    pats = [G.get(ch, "|".join(["....."] * 7)).split("|") for ch in text]
    rows = []
    for r in range(7):
        rows.append(".".join(p[r] for p in pats))   # one blank column between
    return rows



# ----------------------------------------------------------------- the bezel
#
# The cabinet surround Panel.qml draws around the game. Same pixel grid as the
# game -- the whole image is magnified by the same integer the frame is -- so
# it reads as one object rather than a window with a picture in it.
#
# Layout, in native pixels around the 320x240 screen:
#
#   marquee   28 rows across the top: QUATTRO GP in the HUD font at 3x,
#             between two chequer bands, like the cabinet header card
#   pillars   12 columns each side, carrying kerb-red/white diagonal livery
#   card      26 rows along the bottom: the controls, white keys/yellow verbs,
#             because a cabinet tells you how to play on the cabinet
#
# Colours are the game's own: kerb red/white, tarmac grey, HUD yellow. Nothing
# sampled from anywhere else.
BEZEL_SIDE, BEZEL_TOP, BEZEL_BOT = 12, 28, 26
BEZEL_W = 320 + 2 * BEZEL_SIDE
BEZEL_H = 240 + BEZEL_TOP + BEZEL_BOT

BZ_BASE   = (23, 23, 27)      # cabinet plastic
BZ_EDGE   = (0, 0, 0)         # outer edge / screen frame
BZ_LIP    = (45, 45, 52)      # top-light on the plastic
BZ_RED    = (191, 34, 13)     # the kerb red
BZ_WHITE  = (238, 238, 235)   # the kerb white
BZ_YELLOW = (233, 191, 49)    # the HUD's TIME yellow
BZ_SCREW  = (98, 98, 104)


def _bz_text(px, img, text, cx, y, colour, scale=1):
    rows = _font_rows(text)
    w = len(rows[0]) * scale
    _stamp_logo(img, rows, cx - w // 2, y, scale, colour)
    return w


def make_bezel():
    img = Image.new("RGBA", (BEZEL_W, BEZEL_H), BZ_BASE + (255,))
    px = img.load()
    d = ImageDraw.Draw(img)

    hole = (BEZEL_SIDE, BEZEL_TOP, BEZEL_SIDE + 320, BEZEL_TOP + 240)

    # Outer edge and a one-pixel lit lip under it.
    d.rectangle((0, 0, BEZEL_W - 1, BEZEL_H - 1), outline=BZ_EDGE + (255,))
    d.rectangle((1, 1, BEZEL_W - 2, BEZEL_H - 2), outline=BZ_LIP + (255,))

    # The screen: a two-pixel black rim so the tube reads as inset, and the
    # 320x240 inside it punched to transparent -- the game shows through.
    d.rectangle((hole[0] - 2, hole[1] - 2, hole[2] + 1, hole[3] + 1),
                outline=BZ_EDGE + (255,))
    d.rectangle((hole[0] - 1, hole[1] - 1, hole[2], hole[3]),
                outline=BZ_EDGE + (255,))
    d.rectangle((hole[0], hole[1], hole[2] - 1, hole[3] - 1), fill=(0, 0, 0, 0))

    # Side pillars: kerb livery, diagonal, running the full height between
    # marquee and card, inset by a one-pixel black frame.
    for x0 in (3, BEZEL_W - 9):
        x1 = x0 + 5
        y0, y1 = BEZEL_TOP + 2, BEZEL_TOP + 238
        d.rectangle((x0 - 1, y0 - 1, x1 + 1, y1 + 1), outline=BZ_EDGE + (255,))
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                band = ((x + y) // 5) % 3
                px[x, y] = (BZ_RED if band == 0 else
                            BZ_WHITE if band == 1 else BZ_BASE) + (255,)

    # Corner screws.
    for sx, sy in ((4, 4), (BEZEL_W - 6, 4), (4, BEZEL_H - 6), (BEZEL_W - 6, BEZEL_H - 6)):
        d.rectangle((sx, sy, sx + 1, sy + 1), fill=BZ_SCREW + (255,))

    # Marquee: the name at 3x with a red drop shadow, chequer blocks filling
    # the header out to the sides the way the board's own title card does.
    rows = _font_rows("QUATTRO GP")
    tw = len(rows[0]) * 3
    tx = (BEZEL_W - tw) // 2
    _stamp_logo(img, rows, tx + 1, 4, 3, BZ_RED)
    _stamp_logo(img, rows, tx, 3, 3, BZ_WHITE)
    for bx0 in (16, BEZEL_W - 40):
        for y in range(6, 22):
            for x in range(bx0, bx0 + 24):
                if x < tx - 8 or x > tx + tw + 8:
                    on = ((x // 4) + (y // 4)) % 2 == 0
                    px[x, y] = (BZ_WHITE if on else BZ_EDGE) + (255,)

    # Card: an inset panel with the controls in two lines.
    cy0 = BEZEL_TOP + 240 + 3
    d.rectangle((3, cy0 - 1, BEZEL_W - 4, BEZEL_H - 4), outline=BZ_EDGE + (255,))
    d.rectangle((4, cy0, BEZEL_W - 5, BEZEL_H - 5), fill=(16, 16, 19, 255))
    _bz_text(px, img, "< > STEER   UP THROTTLE   DOWN BRAKE", BEZEL_W // 2, cy0 + 2, BZ_WHITE)
    _bz_text(px, img, "SPACE GEAR   ENTER START   ESC QUIT", BEZEL_W // 2, cy0 + 11, BZ_YELLOW)

    img.save(os.path.join(HERE, "bezel.png"))
    print(f"{'bezel':14s} -> {BEZEL_W}x{BEZEL_H}  (drawn, not cut)")


def _wrapped_profile(x, w, ks, phases):
    """Summed sines that wrap exactly across a strip of width w.

    Only integer numbers of cycles, so the value at x = w equals the value at
    x = 0 and the strip tiles seamlessly. The cut horizons do not have this
    property, which is why the old seaside strip has a join down it.
    """
    v = 0.0
    weights = (0.55, 0.30, 0.15)
    for k, ph, wt in zip(ks, phases, weights):
        v += math.sin(2.0 * math.pi * k * x / w + ph) * wt
    return v


def make_seaside_strip():
    w, h = SEASIDE_STRIP
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()

    water = _rgb(SEASIDE_WATER)
    sea_line = h - 7          # where open water meets the sky

    for x in range(w):
        for y in range(sea_line, h):
            px[x, y] = water + (255,)

    # Three ranks of headland. Each is drawn only where its profile rises
    # ABOVE the waterline, so the land comes and goes along the horizon
    # instead of running unbroken across it -- which is the difference
    # between a coast and a field.
    ranks = (
        (_rgb(SEASIDE_RIDGES[0]), (3, 7, 13), (0.4, 2.1, 5.0), 20.0, 3.0),
        (_rgb(SEASIDE_RIDGES[1]), (2, 5, 11), (2.7, 0.9, 3.8), 16.0, 3.6),
        (_rgb(SEASIDE_RIDGES[2]), (1, 4,  9), (5.1, 3.3, 1.2), 12.0, 4.0),
    )
    for colour, ks, phases, amp, bias in ranks:
        for x in range(w):
            rise = _wrapped_profile(x, w, ks, phases) * amp - bias
            if rise <= 0:
                continue                      # this stretch is open water
            top = int(sea_line - rise)
            for y in range(max(top, 0), sea_line):
                px[x, y] = colour + (255,)

    return img


def erase_sun(tile, box):
    """Paint a region out with the sky colour from the same row.

    The sky is a vertical gradient and flat within a row, so a per-row sample
    taken from a column the sun never reaches rebuilds it exactly. Only
    pixels clearly brighter and yellower than that sample are touched, so the
    sun's glow goes with it and the clouds and mountains do not.
    """
    x0, y0, x1, y1 = box
    px = tile.load()
    for y in range(y0, min(y1, tile.height)):
        ref = px[4, y]
        for x in range(x0, min(x1, tile.width)):
            p = px[x, y]
            if p[1] > ref[1] + 18 and p[2] < 140:
                px[x, y] = ref
    return tile


def make_backdrop(board, spec):
    """Cut one course's horizon strip out of a mood-board tile."""
    tile = board.crop(spec["box"]).convert("RGB")
    if spec["sun"]:
        tile = erase_sun(tile, spec["sun"])

    top, bottom = spec["band"]
    band = tile.crop((0, top, tile.width, bottom))

    h = spec["height"]
    w = round(band.width * h / band.height)
    strip = quantise(band.resize((w, h), Image.BOX).convert("RGBA"), spec["colours"])

    # Mirror, so the wrap has no seam.
    out = Image.new("RGBA", (w * 2, h))
    out.paste(strip, (0, 0))
    out.paste(ImageOps.mirror(strip), (w, 0))
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    board = Image.open(BOARD).convert("RGB")
    index = {}

    for name, box, native, colours, mode, scrub in SPRITES:
        crop = board.crop(box).convert("RGBA")
        cut = {"dark": cut_dark, "seed": cut_seed, "key": cut_key}[mode](crop)
        # Cars are solid objects; anything else (marshal tower, sign poles,
        # tree canopies) has real daylight in it that must stay transparent.
        if name.startswith(("car_", "rival_")):
            cut = fill_holes(cut, crop)
        cut = trim(cut)
        out = quantise(apply_scrub(fit(cut, native), scrub), colours)
        out.save(os.path.join(OUT, name + ".png"))
        opaque = sum(1 for p in out.convert("RGBA").getdata() if p[3] > 0)
        index[name] = {"w": native[0], "h": native[1]}
        print(f"{name:14s} src {cut.width:3d}x{cut.height:<3d} -> {native[0]:3d}x{native[1]:<3d} {opaque:5d}px")

    box, native, colours = BACKDROP
    back = board.crop(box).resize(native, Image.BOX)
    back = quantise(back.convert("RGBA"), colours)
    back.save(os.path.join(HERE, "backdrop.png"))
    print(f"{'backdrop':14s} -> {native[0]}x{native[1]}")

    for name, spec in BACKDROPS.items():
        if name == "backdrop_seaside":
            continue                      # drawn below, not cut
        strip = make_backdrop(board, spec)
        strip.save(os.path.join(HERE, name + ".png"))
        print(f"{name:14s} -> {strip.width}x{strip.height}")

    seaside = make_seaside_strip()
    seaside.save(os.path.join(HERE, "backdrop_seaside.png"))
    print(f"{'backdrop_seaside':14s} -> {seaside.width}x{seaside.height}  "
          f"(drawn, not cut)")

    sunset = make_sunset_strip()
    sunset.save(os.path.join(HERE, "backdrop_sunset.png"))
    print(f"{'backdrop_sunset':14s} -> {sunset.width}x{sunset.height}  (drawn, not cut)")

    sun = make_sunset_sun()
    sun.save(os.path.join(HERE, "sun_sunset.png"))
    print(f"{'sun_sunset':14s} -> {sun.width}x{sun.height}")

    for nm, img in (("gantry", make_gantry()),
                    ("gantry_finish", make_gantry_finish())):
        img.save(os.path.join(OUT, nm + ".png"))
        index[nm] = {"w": GANTRY[0], "h": GANTRY[1]}
        print(f"{nm:14s} -> {img.width}x{img.height}  (drawn, not cut)")

    make_bezel()

    # Road palette, read off the mockup so the shaded road matches the artwork
    # it carries. Verified sample points, not guesses.
    pal = {
        "sky":        "#2a84e4",
        "skyHaze":    "#7fb8e8",
        "cloud":      "#dddedf",
        "grassA":     "#349515",
        "grassB":     "#4aa316",   # matches Track.js/Road.qml; this file is
                                   # reference output, nothing reads it live
        "road":       "#3a3b3b",
        "roadAlt":    "#363737",
        "rumbleA":    "#bf220d",
        "rumbleB":    "#d7d5d2",
        "lane":       "#eeeeeb",
    }
    with open(os.path.join(HERE, "palette.json"), "w") as f:
        json.dump({"colors": pal, "sprites": index}, f, indent=2)
    print("\npalette written")


if __name__ == "__main__":
    main()
