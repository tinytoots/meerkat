#!/usr/bin/env python3
"""
Checks the meerkat's geometry without rendering it.

Critter.swift lays the animal out in a 100 x 130 design space, and a Canvas
clips to exactly that. A shape whose coordinates stray outside gets silently
sliced off on every frame, which is easy to write and hard to notice. This
script mirrors the same arithmetic, sweeps the whole animation cycle for every
mood, and reports anything that leaves the canvas or lands somewhere it should
not.

    ./scripts/geometry_check.py

Keep it in step with Critter.swift by hand: it is a model of that file, not a
reader of it.
"""

import math
import sys

W, H = 100.0, 130.0
MOODS = ["idle", "working", "attention", "done", "failed"]

problems = []
notes = []


def complain(mood, what, detail):
    problems.append("%-9s %-22s %s" % (mood, what, detail))


def bounds(mood, what, x0, y0, x1, y1, pad=0.0):
    """Assert a shape's bounding box stays inside the canvas."""
    if x0 < -pad or y0 < -pad or x1 > W + pad or y1 > H + pad:
        complain(mood, what,
                 "box (%.1f, %.1f)-(%.1f, %.1f) escapes 0,0-%g,%g"
                 % (x0, y0, x1, y1, W, H))


def wave(phase, speed, offset=0.0):
    return math.sin(phase * speed + offset)


def motion(mood, phase, bounce=0.0):
    """Mirrors the computed properties at the top of MeerkatCritter."""
    speed = 1.9 if mood == "working" else 1.0
    amount = 1.4 if mood == "working" else 0.9
    dx = wave(phase, speed) * amount

    breath = wave(phase, 2.1) * 0.8

    if mood == "working":
        head_scan = wave(phase, 1.35) * 3.4
    elif mood == "attention":
        head_scan = wave(phase, 6.0) * 1.1
    else:
        head_scan = 0.0

    dy = 0.0
    if mood == "attention":
        dy -= abs(wave(phase, 3.4)) * 3.2
    elif mood == "idle":
        dy += 2.0
    elif mood == "failed":
        dy += 3.0
    dy -= bounce * 9.0
    dy = max(dy, -10.0)

    return dx, dy, breath, head_scan


def bezier(p0, p1, p2, p3, t):
    u = 1 - t
    return (
        u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
        u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
    )


def rotate(x, y, degrees):
    """SwiftUI's rotate(by:) in a +y-down space."""
    r = math.radians(degrees)
    return (x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r))


def check(mood, phase, bounce):
    dx, dy, breath, head_scan = motion(mood, phase, bounce)
    x = dx + head_scan
    celebrating = (mood == "done") or bounce > 0.05

    # Halo
    bounds(mood, "halo", 14 + dx, 8 + dy * 0.3,
           14 + dx + 72, 8 + dy * 0.3 + 116)

    # Tail: a 9pt stroke, so half a width of slack all round.
    flick = wave(phase, 2.6) * 4.0 if mood == "working" else wave(phase, 0.9) * 1.6
    tip = (15 + dx - flick * 0.4, 74 + dy - flick)
    p0 = (42 + dx, 108 + dy)
    p1 = (24 + dx, 114 + dy)
    p2 = (12 + dx, 98 + dy)
    xs, ys = [], []
    for i in range(41):
        bx, by = bezier(p0, p1, p2, tip, i / 40.0)
        xs.append(bx)
        ys.append(by)
    bounds(mood, "tail", min(xs) - 4.5, min(ys) - 4.5, max(xs) + 4.5, max(ys) + 4.5)

    # The dark tip should sit on the curve, not beside it.
    near = min(range(41), key=lambda i: abs(ys[i] - (84 + dy - flick * 0.7)))
    tip_start_x = 14 + dx - flick * 0.3
    if abs(xs[near] - tip_start_x) > 2.0:
        complain(mood, "tail tip",
                 "starts at x=%.1f but the curve is at x=%.1f there"
                 % (tip_start_x, xs[near]))

    # Ears, behind the head.
    droop = 6.0 if mood == "failed" else (2.5 if mood == "idle" else 0.0)
    for side in (-1, 1):
        cx = 50 + side * 21 + x * 0.8
        cy = 25 + dy + droop
        bounds(mood, "ear", cx - 7, cy - 6.5, cx + 7, cy + 6.5)

    # Torso.
    t0 = (50 + dx, 44 + dy)
    t1 = (26 + dx, 102 + dy + breath)
    t2 = (74 + dx, 102 + dy + breath)
    xs, ys = [], []
    for a, b, c, d in (
        (t0, (34 + dx, 48 + dy), (24 + dx, 74 + dy), t1),
        (t1, (30 + dx, 118 + dy + breath), (70 + dx, 118 + dy + breath), t2),
        (t2, (76 + dx, 74 + dy), (66 + dx, 48 + dy), t0),
    ):
        for i in range(21):
            px, py = bezier(a, b, c, d, i / 20.0)
            xs.append(px)
            ys.append(py)
    bounds(mood, "torso", min(xs), min(ys), max(xs), max(ys))

    # Belly, which must stay inside the torso.
    bounds(mood, "belly", 34 + dx, 62 + dy, 66 + dx, 104 + dy + breath)
    if 34 + dx < min(xs) or 66 + dx > max(xs):
        complain(mood, "belly", "wider than the torso it sits on")

    # Feet.
    for side in (-1, 1):
        cx = 50 + side * 11 + dx
        bounds(mood, "foot", cx - 9, 112 + dy + breath, cx + 9, 123 + dy + breath)

    # Arms: a rounded rect rotated about the shoulder.
    arm_tips = []
    for side in (-1, 1):
        degrees = side * (48 if celebrating else 12)
        ax = 50 + side * 15 + dx
        ay = (60 if celebrating else 66) + dy
        top = -20 if celebrating else -3
        corners = [(-4, top), (4, top), (-4, top + 23), (4, top + 23)]
        pts = [rotate(cxx, cyy, degrees) for cxx, cyy in corners]
        px = [ax + p[0] for p in pts]
        py = [ay + p[1] for p in pts]
        bounds(mood, "arm", min(px), min(py), max(px), max(py))
        # The far end of the arm, for the celebration check below.
        far = rotate(0, top if celebrating else top + 23, degrees)
        arm_tips.append((ax + far[0], ay + far[1]))

    if celebrating:
        left, right = arm_tips
        if abs(left[0] - right[0]) < 20:
            complain(mood, "arms",
                     "raised tips converge at x=%.1f and %.1f instead of spreading"
                     % (left[0], right[0]))
        shoulder_y = 60 + dy
        if left[1] > shoulder_y or right[1] > shoulder_y:
            complain(mood, "arms",
                     "'raised' tips at y=%.1f/%.1f are below the shoulder at y=%.1f"
                     % (left[1], right[1], shoulder_y))

    # Head.
    hx = 50 + x
    hy = 34 + dy
    bounds(mood, "head", hx - 23, hy - 23, hx + 23, hy + 22)

    # Eyes must stay inside their dark patches, in head-local coordinates.
    patch_wide = 21 if mood == "attention" else 19
    r = 4.4 if mood == "attention" else 3.6
    if mood in ("working", "attention"):
        for side in (-1, 1):
            cx = side * 10
            if cx - r < cx - patch_wide / 2 or cx + r > cx + patch_wide / 2:
                complain(mood, "eye", "white is wider than its mask patch")
            look = wave(phase, 1.35) * 1.1 if mood == "working" else 0.0
            pupil = r * 0.52
            if abs(look) + pupil > r:
                complain(mood, "pupil",
                         "drifts outside the eye white (look=%.2f)" % look)

    # The muzzle and nose must stay inside the skull. Both are ellipses
    # inscribed in their rects, so the points to test are the edge midpoints --
    # an inscribed ellipse never reaches its rect's corners.
    for name, x0, y0, x1, y1 in (
        ("muzzle", -11, 2, 11, 21),
        ("nose", -4, 12, 4, 18),
    ):
        mx, my = (x0 + x1) / 2.0, (y0 + y1) / 2.0
        for px, py in ((mx, y0), (mx, y1), (x0, my), (x1, my)):
            if (px / 23.0) ** 2 + ((py + 0.5) / 22.5) ** 2 > 1.0:
                complain(mood, name,
                         "extreme point (%g, %g) pokes out of the skull" % (px, py))

    # Attention badge.
    if mood == "attention":
        bx, by = 74 + x, max(9.5, 13 + dy)
        bounds(mood, "alert badge", bx - 9, by - 9, bx + 9, by + 9)

    # Sparkles, which should be in the air rather than on the face.
    if mood == "done":
        for sx, sy, offset in ((78, 16, 0.0), (22, 24, 1.1), (84, 52, 2.2)):
            twinkle = 0.35 + 0.65 * abs(math.sin(phase * 2.4 + offset))
            rr = 2.0 + twinkle * 1.8
            px, py = sx + x, sy + dy
            bounds(mood, "sparkle", px - rr, py - rr, px + rr, py + rr)
            if ((px - hx) / 23.0) ** 2 + ((py - hy) / 22.5) ** 2 < 1.0:
                complain(mood, "sparkle",
                         "(%g, %g) is inside the head, so it reads as a blemish"
                         % (sx, sy))


def main():
    # Sweep a full cycle of every motion, and the whole celebration hop.
    steps = 240
    for mood in MOODS:
        for i in range(steps):
            phase = i * (12.0 / steps)
            check(mood, phase, 0.0)
        # The hop applies to any mood, since a finish can land on any row.
        for i in range(25):
            u = i / 24.0
            bounce = min(1.0, math.sin(u * math.pi) * (1 - u) / 0.579)
            check(mood, u * 1.1, bounce)

    print()
    print("Meerkat geometry check")
    print("======================")
    print("moods: %s" % ", ".join(MOODS))
    print("canvas: %g x %g, swept over a full animation cycle plus the hop" % (W, H))
    print()

    if problems:
        seen = []
        for p in problems:
            if p not in seen:
                seen.append(p)
        for p in seen:
            print("  FAIL  %s" % p)
        print()
        print("  %d distinct problem(s)" % len(seen))
        return 1

    print("  all shapes stay inside the canvas")
    print("  eyes inside their mask patches, muzzle and nose inside the skull")
    print("  belly within the torso, raised arms spread above the shoulder")
    print("  tail tip follows the tail curve, sparkles clear of the head")
    print()
    print("  PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
