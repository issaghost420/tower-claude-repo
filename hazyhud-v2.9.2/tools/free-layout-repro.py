"""Qt-free model of FreeCanvas geometry math.

Replicates _clamp_to_canvas and the old vs new add_tile/layout paths on plain
rects so the failure can be reproduced without a display server.
"""


def clamp(g, cw, ch):
    x, y, w, h = g
    if cw > 0 and w > cw:
        w = cw
    if ch > 0 and h > ch:
        h = ch
    if cw > 0:
        x = max(0, min(x, cw - w))
    if ch > 0:
        y = max(0, min(y, ch - h))
    return (x, y, w, h)


# Edge's saved layout from a 2560x1400 window
SAVED = {
    "cpu":     (8, 8, 840, 420),
    "gpu0":    (856, 8, 840, 420),
    "gpu1":    (1704, 8, 840, 420),
    "system":  (8, 436, 840, 480),
    "aqua":    (856, 436, 840, 480),
    "fans":    (1704, 436, 840, 480),
}
PRESHOW = (640, 480)   # canvas size at _rebuild_free time, before show()
REAL = (2560, 1400)    # size the compositor eventually hands over


def old_path():
    """v2.8.0: clamp at add_tile against the pre-show size, then clamp again
    on resize. The second clamp is a no-op because everything already fits."""
    tiles = {n: clamp(g, *PRESHOW) for n, g in SAVED.items()}
    tiles = {n: clamp(g, *REAL) for n, g in tiles.items()}
    return tiles


def new_path():
    """v2.9.0: _want is untouched by clamping; layout recomputes from _want
    once the canvas is live."""
    want = dict(SAVED)                       # add_tile records the wish
    # pre-show layout pass is refused (canvas not live) — nothing happens
    tiles = {n: clamp(g, *REAL) for n, g in want.items()}
    return tiles


def report(name, tiles):
    print(f"\n{name}")
    xs = [g[0] for g in tiles.values()]
    ys = [g[1] for g in tiles.values()]
    area = sum(g[2] * g[3] for g in tiles.values())
    for n, g in tiles.items():
        print(f"  {n:8} x={g[0]:5} y={g[1]:5} w={g[2]:5} h={g[3]:5}")
    print(f"  bounding box: x {min(xs)}..{max(xs)}  y {min(ys)}..{max(ys)}")
    print(f"  canvas coverage: {area / (REAL[0] * REAL[1]):.1%}")


report("v2.8.0 (current)", old_path())
report("v2.9.0 (fixed)", new_path())

assert new_path() == SAVED, "fixed path must restore the saved layout exactly"
print("\nOK: fixed path reproduces the saved layout byte for byte.")
