#!/usr/bin/env python3
"""Free-mode layout regression test. Runs offscreen, touches nothing real.

    QT_QPA_PLATFORM=offscreen python3 tools/verify_free_layout.py

QSettings is redirected to a throwaway directory, so your saved tile
positions, renames and window geometry are not read or written. The config is
synthesised in a temp file too — your ~/.config/hazyhud is never opened.

Four checks, each one a bug that shipped in 2.8.0:

  1. cold start        — tiles fill the window instead of piling in a corner
  2. saved layout      — a layout saved at 2560x1400 comes back byte-identical
  3. shrink and grow   — squeezing the window doesn't permanently crush tiles
  4. untouched reflow  — tiles you never dragged re-flow to fit a new size

Exit code 0 = all passed.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from render_preview import FakeCC, FakeCollector, fake_cooling, fake_metrics  # noqa: E402

CONFIG = """
layout:
  mode: free
  columns: 3
  margin: 8
  spacing: 8
  snap_to_edges: true
  allow_overlap: false
  widgets:
    cpu:     {row: 0, col: 0}
    gpu0:    {row: 0, col: 1}
    gpu1:    {row: 0, col: 2}
    system:  {row: 1, col: 0}
    aqua:    {row: 1, col: 1}
    fans:    {row: 1, col: 2}
window:
  remember_geometry: false
coolercontrol:
  enabled: false
"""

BIG = (2560, 1400)
SMALL = (900, 500)

_failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail else ""))
    if not ok:
        _failures.append(name)


def geoms(window) -> dict:
    return {
        t.name: (t.geometry().x(), t.geometry().y(),
                 t.geometry().width(), t.geometry().height())
        for t in window._canvas.tiles()
    }


def coverage(g: dict, size) -> float:
    return sum(w * h for _, _, w, h in g.values()) / (size[0] * size[1])


def spread(g: dict) -> int:
    """How far apart the tile origins are — a pile-up collapses this to ~0."""
    xs = [v[0] for v in g.values()]
    ys = [v[1] for v in g.values()]
    return (max(xs) - min(xs)) + (max(ys) - min(ys))


def build(qtapp, cfg_path, size):
    from hazyhud.config import SharedConfig

    window = qtapp.HazyHudWindow(SharedConfig(cfg_path))
    window.resize(*size)
    window.show()
    window._render(fake_metrics(), fake_cooling())
    _app.processEvents()
    window.grab()  # force a real paint — this is where layout lands
    _app.processEvents()
    return window


def main() -> int:
    global _app
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QApplication

    scratch = Path(tempfile.mkdtemp(prefix="hazyhud-verify-"))
    QSettings.setDefaultFormat(QSettings.IniFormat)
    QSettings.setPath(QSettings.IniFormat, QSettings.UserScope, str(scratch))
    cfg_path = scratch / "config.yaml"
    cfg_path.write_text(CONFIG)

    import hazyhud.qt.app as qtapp

    qtapp.HazyHudCollector = FakeCollector
    qtapp.CoolerControlClient = lambda **kwargs: FakeCC()  # noqa: E731

    _app = QApplication([])
    print(f"scratch: {scratch}\n")

    # 1 — cold start, no saved geometry at all
    print("1. cold start at 2560x1400")
    w = build(qtapp, cfg_path, BIG)
    cold = geoms(w)
    for name, g in cold.items():
        print(f"     {name:8} {g}")
    check("tiles are spread out, not piled", spread(cold) > 800,
          f"origin spread {spread(cold)}px")
    check("tiles cover the window", coverage(cold, BIG) > 0.55,
          f"{coverage(cold, BIG):.0%} covered")
    check("no tile is degenerate", all(x[2] > 100 and x[3] > 60 for x in cold.values()))
    w.close()

    # 2 — a deliberate layout survives a restart
    print("\n2. saved layout restored after restart")
    import json
    placed = {
        "cpu": [40, 40, 700, 400], "gpu0": [780, 40, 700, 400],
        "gpu1": [1520, 40, 700, 400], "system": [40, 480, 700, 440],
        "aqua": [780, 480, 700, 440], "fans": [1520, 480, 700, 440],
    }
    QSettings("hazyhud", "hazyhud").setValue("free_geometry", json.dumps(placed))
    w = build(qtapp, cfg_path, BIG)
    got = geoms(w)
    want = {k: tuple(v) for k, v in placed.items()}
    # only the saved tiles can "restore" — a tile with no saved geometry
    # (mode_switcher here) seeds wherever the reflow puts it, so compare the
    # saved subset, not the whole dict
    restored = all(got.get(k) == v for k, v in want.items())
    check("restored byte for byte", restored,
          "" if restored else f"got {got}")
    w.close()

    # 3 — shrink, then grow: the crush must not be permanent
    print("\n3. shrink to 900x500, grow back to 2560x1400")
    w = build(qtapp, cfg_path, BIG)
    w.resize(*SMALL)
    _app.processEvents()
    w.grab()
    _app.processEvents()
    squeezed = geoms(w)
    check("tiles fit the small window", all(
        x + wd <= SMALL[0] + 4 and y + ht <= SMALL[1] + 60
        for x, y, wd, ht in squeezed.values()),
        f"{squeezed}")
    w.resize(*BIG)
    _app.processEvents()
    w.grab()
    _app.processEvents()
    regrown = geoms(w)
    back = all(regrown.get(k) == v for k, v in want.items())
    check("original layout comes back", back,
          "" if back else f"got {regrown}")
    w.close()

    # 4 — untouched tiles re-flow to whatever size the window opens at
    print("\n4. untouched tiles reflow at a different window size")
    QSettings("hazyhud", "hazyhud").remove("free_geometry")
    w = build(qtapp, cfg_path, SMALL)
    small_cold = geoms(w)
    check("fills the small window too", coverage(small_cold, SMALL) > 0.55,
          f"{coverage(small_cold, SMALL):.0%} covered")
    check("differs from the big-window layout", small_cold != cold)
    w.close()

    print()
    if _failures:
        print(f"FAILED: {len(_failures)} check(s) — {', '.join(_failures)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
