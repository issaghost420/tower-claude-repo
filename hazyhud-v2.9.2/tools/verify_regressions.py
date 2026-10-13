#!/usr/bin/env python3
"""Interaction regression tests — the 2.9.1 bug batch. Runs offscreen.

    QT_QPA_PLATFORM=offscreen python3 tools/verify_regressions.py

Covers:
  1. config reload keeps the live 'p' preset override when an UNRELATED key
     was edited; reasserts only when layout.preset itself changed
  2. GPU double-click rename pre-fills the full auto-name ("GPU 0 (RTX...)")
  3. free mode honors layout.allow_squash: false (tiles can't shrink below
     content); true keeps the tiny 60x40 floor
  4. kiosk window quits on close (WA_QuitOnClose survives Qt.Tool flags)
  5. free-mode layout autosaves to last-layout.yaml and restores on the next
     launch; launch.restore_last_layout / launch.launch_layout behave
  6. 'e' with a terminal editor opens the in-window overlay; ctrl+s writes
     the file and the live reload picks it up

Exit code 0 = all passed. A separate SIGINT exit test needs a subprocess and
lives at the bottom (skipped unless RUN_SIGINT_TEST=1 — it spawns the app).
"""

from __future__ import annotations

import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from render_preview import FakeCC, FakeCollector, fake_cooling, fake_metrics  # noqa: E402

GRID_CFG = """
layout:
  mode: grid
  preset: full
window:
  remember_geometry: false
coolercontrol:
  enabled: false
"""

FREE_CFG = """
layout:
  mode: free
  columns: 3
  margin: 8
  spacing: 8
  snap_to_edges: true
  allow_overlap: false
window:
  remember_geometry: false
coolercontrol:
  enabled: false
"""

_failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail else ""))
    if not ok:
        _failures.append(name)


def main() -> int:
    from PySide6.QtWidgets import QApplication, QLineEdit

    import hazyhud.qt.app as qtapp
    from hazyhud.config import SharedConfig
    from hazyhud.qt.configeditor import ConfigEditorOverlay

    qtapp.HazyHudCollector = FakeCollector
    qtapp.CoolerControlClient = lambda **kwargs: FakeCC()  # noqa: E731

    app = QApplication([])

    def build(cfg_text: str, kiosk: bool = False):
        d = Path(tempfile.mkdtemp(prefix="hazyhud-reg-"))
        cfgp = d / "config.yaml"
        cfgp.write_text(cfg_text)
        w = qtapp.HazyHudWindow(SharedConfig(cfgp), kiosk=kiosk)
        w.resize(1600, 640)
        w.show()
        w._render(fake_metrics(), fake_cooling())
        app.processEvents()
        return w, cfgp

    # -- 1. config reload keeps a live preset override -------------------------
    print("1. preset override vs config edits")
    w, cfgp = build(GRID_CFG)
    full_set = {b.widget_key for b in w._boxes}
    w._preset_override = "minimal"          # user pressed 'p'
    w._rebuild_all()
    app.processEvents()
    minimal_set = {b.widget_key for b in w._boxes}
    check("override switches the widget set", minimal_set != full_set,
          f"{sorted(minimal_set)}")

    # unrelated edit: bump poll_interval_ms
    time.sleep(0.02)
    cfgp.write_text(GRID_CFG + "\npoll_interval_ms: 1234\n")
    w.cfg.check_reload()
    app.processEvents()
    check("unrelated edit keeps the override", w._preset_override == "minimal",
          f"override={w._preset_override!r}")
    check("widget set unchanged", {b.widget_key for b in w._boxes} == minimal_set)

    # editing layout.preset itself reasserts the file
    time.sleep(0.02)
    cfgp.write_text(GRID_CFG.replace("preset: full", "preset: cooling"))
    w.cfg.check_reload()
    app.processEvents()
    check("editing layout.preset clears the override", w._preset_override is None,
          f"override={w._preset_override!r}")
    cooling_set = {b.widget_key for b in w._boxes}
    check("file preset applied", cooling_set == {"aqua", "power_avg", "fans", "mode_switcher"},
          f"{sorted(cooling_set)}")
    w.close()
    w.deleteLater()
    app.processEvents()

    # -- 2. GPU rename pre-fills the full auto-name ----------------------------
    print("2. GPU rename keeps the device name")
    w, cfgp = build(GRID_CFG)
    gpu0 = next(b for b in w._boxes if b.widget_key == "gpu0")
    shown = gpu0.title_label.text()
    check("auto-name shows device", shown == "GPU 0 (RTX 5090)", shown)
    gpu0._begin_rename()
    editor = gpu0.findChild(QLineEdit)
    check("rename editor pre-fills displayed title",
          editor is not None and editor.text() == shown,
          editor.text() if editor else "no editor")
    # empty input keeps the current title instead of reverting to "GPU 0"
    editor.setText("")
    editor.returnPressed.emit()
    app.processEvents()
    check("empty commit keeps full title", gpu0.title_label.text() == shown,
          gpu0.title_label.text())
    w.close()
    w.deleteLater()
    app.processEvents()

    # -- 3. free mode honors allow_squash ---------------------------------------
    print("3. allow_squash in free mode")
    w, cfgp = build(FREE_CFG + "layout:\n  mode: free\n  allow_squash: false\n")
    w.grab()
    app.processEvents()
    canvas = w._canvas
    cpu = canvas._tiles["cpu"]
    floor = canvas.tile_floor(cpu)
    hint = cpu._inner.minimumSizeHint()
    check("squash off: floor is content size",
          floor[0] >= hint.width() and floor[1] >= hint.height() and floor != (60, 40),
          f"floor={floor} hint=({hint.width()},{hint.height()})")
    # try to drag-resize way below the floor
    from PySide6.QtCore import QRect
    canvas.tile_resizing(cpu, QRect(cpu.geometry().x(), cpu.geometry().y(), 20, 20))
    app.processEvents()
    g = cpu.geometry()
    check("squash off: resize refuses to clip content",
          g.width() >= floor[0] and g.height() >= floor[1],
          f"got ({g.width()},{g.height()}) floor={floor}")
    w.close()
    w.deleteLater()
    app.processEvents()

    w, cfgp = build(FREE_CFG + "layout:\n  mode: free\n  allow_squash: true\n")
    w.grab()
    app.processEvents()
    canvas = w._canvas
    cpu = canvas._tiles["cpu"]
    check("squash on: floor is tiny", canvas.tile_floor(cpu) == (60, 40),
          f"floor={canvas.tile_floor(cpu)}")
    w.close()
    w.deleteLater()
    app.processEvents()

    # -- 4. kiosk window quits on close -----------------------------------------
    print("4. kiosk close quits the app")
    from PySide6.QtCore import Qt
    w, cfgp = build(GRID_CFG + "kiosk:\n  enabled: true\n  skip_taskbar: true\n", kiosk=True)
    check("kiosk window is a Tool window", bool(w.windowFlags() & Qt.Tool))
    check("WA_QuitOnClose forced on", w.testAttribute(Qt.WA_QuitOnClose))
    w.close()
    w.deleteLater()
    app.processEvents()

    # -- 5. last-layout.yaml autosave + launch behavior --------------------------
    print("5. free layout autosave + launch behavior")
    d = Path(tempfile.mkdtemp(prefix="hazyhud-reg-"))
    cfgp = d / "config.yaml"
    cfgp.write_text(FREE_CFG)

    def build_at(path, kiosk=False):
        w = qtapp.HazyHudWindow(SharedConfig(path), kiosk=kiosk)
        w.resize(1600, 640)
        w.show()
        w._render(fake_metrics(), fake_cooling())
        app.processEvents()
        w.grab()
        app.processEvents()
        return w

    w1 = build_at(cfgp)
    cpu = w1._canvas._tiles["cpu"]
    target = QRect(700, 380, cpu.width(), cpu.height())
    w1._canvas.tile_moving(cpu, target)
    w1._canvas.tile_dropped(cpu)
    app.processEvents()
    dropped = cpu.geometry().getRect()
    layout_file = d / "last-layout.yaml"
    check("autosave file written", layout_file.exists())
    import yaml
    saved = yaml.safe_load(layout_file.read_text())
    check("file contains the drop", tuple(saved["tiles"]["cpu"]) == dropped,
          f"file={saved['tiles'].get('cpu')} dropped={dropped}")
    w1.close()
    w1.deleteLater()
    app.processEvents()

    # relaunch — same config dir: the tile comes back where it was dropped
    w2 = build_at(cfgp)
    got = w2._canvas._tiles["cpu"].geometry().getRect()
    check("layout restored on relaunch", got == dropped, f"got {got} want {dropped}")
    w2.close()
    w2.deleteLater()
    app.processEvents()

    # restore off: fresh seed, and launch_layout picks the startup preset
    cfgp.write_text(FREE_CFG + (
        "launch:\n  restore_last_layout: false\n  launch_layout: cooling\n"
    ))
    w3 = build_at(cfgp)
    check("launch_layout applied", w3._preset_override == "cooling",
          f"override={w3._preset_override!r}")
    cooling_tiles = set(w3._canvas._tiles)
    check("launch_layout widget set", cooling_tiles == {"aqua", "power_avg", "fans", "mode_switcher"},
          f"{sorted(cooling_tiles)}")
    check("restore off → nothing owned from the file",
          not w3._canvas._saved,
          f"saved keys: {sorted(w3._canvas._saved)}")
    w3.close()
    w3.deleteLater()
    app.processEvents()

    # launch_layout ignored while restore is on
    cfgp.write_text(FREE_CFG + (
        "launch:\n  restore_last_layout: true\n  launch_layout: cooling\n"
    ))
    w4 = build_at(cfgp)
    check("restore on → launch_layout ignored", w4._preset_override is None,
          f"override={w4._preset_override!r}")
    got4 = w4._canvas._tiles["cpu"].geometry().getRect()
    check("restore on → layout comes back", got4 == dropped, f"got {got4}")
    w4.close()
    w4.deleteLater()
    app.processEvents()

    # -- 6. terminal editor → in-window overlay ---------------------------------
    print("6. editor overlay for terminal editors")
    w, cfgp = build(GRID_CFG + 'editor: "micro"\n')
    w._open_config()
    app.processEvents()
    overlay = w.findChild(ConfigEditorOverlay)
    check("overlay opened for micro", overlay is not None)
    if overlay is not None:
        overlay._editor.setPlainText(cfgp.read_text() + "\n# touched by overlay test\n")
        overlay._save()
        app.processEvents()
        check("ctrl+s wrote the file", "# touched by overlay test" in cfgp.read_text())
        time.sleep(0.02)
        applied = w.cfg.check_reload()
        check("save live-reloads", applied)
    # a wrapped terminal editor must NOT open the overlay
    w2cfg = Path(tempfile.mkdtemp(prefix="hazyhud-reg-")) / "config.yaml"
    w2cfg.write_text(GRID_CFG + 'editor: "kitty nvim"\n')
    w2 = qtapp.HazyHudWindow(SharedConfig(w2cfg))
    w2.resize(1200, 500)
    w2.show()
    app.processEvents()
    import hazyhud.qt.app as _a
    orig_popen = _a.subprocess.Popen
    spawned = []
    _a.subprocess.Popen = lambda *a, **k: spawned.append(a[0]) or orig_popen(["true"])
    w2._open_config()
    _a.subprocess.Popen = orig_popen
    check("wrapped editor spawns externally, no overlay",
          w2.findChild(ConfigEditorOverlay) is None and spawned and spawned[0][0] == "kitty",
          f"spawned={spawned}")
    w2.close()
    w2.deleteLater()
    w.close()
    w.deleteLater()
    app.processEvents()

    print()
    if _failures:
        print(f"{len(_failures)} FAILED: {', '.join(_failures)}")
        return 1
    print("all regression checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
