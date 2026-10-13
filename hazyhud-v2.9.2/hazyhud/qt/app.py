"""HazyHud Qt HUD — the primary frontend.

One window, three loops:
- QTimer poll (config: poll_interval_ms) → QThreadPool worker samples the
  HazyHudCollector and the CoolerControl daemon → widgets update on the
  main thread via signals
- config mtime check on every tick → save config.yaml, HUD re-themes and
  re-layouts live, no restart
- Qt's event loop for keys/mouse

Keys:  q quit · r reset min/max & averages · m focus mode switcher
       h toggle help bar · e open config in your editor

Kiosk: `hazyhud --kiosk` or `kiosk.enabled: true` — frameless, always on
top, pinned to the configured screen. Built for a dedicated panel that is
disowned by the window manager, present on every virtual desktop.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Optional

from PySide6.QtCore import (
    QObject,
    QPropertyAnimation,
    QRect,
    QSettings,
    Qt,
    QThreadPool,
    QTimer,
    QRunnable,
    Signal,
    Slot,
)
from PySide6.QtGui import QGuiApplication, QKeySequence, QShortcut
from PySide6.QtWidgets import QGraphicsOpacityEffect, QGridLayout, QLabel, QVBoxLayout, QWidget

from .. import __version__
from ..cc_client import CCUnavailable, CoolerControlClient
from ..collector import HazyHudCollector
from ..config import SharedConfig
from ..models import CoolingSnapshot, MetricsSnapshot
from . import theme
from .canvas import FreeCanvas
from .configeditor import TERMINAL_EDITORS, ConfigEditorOverlay
from .helpbar import HelpBar
from .widgets import (
    AquaWidget,
    CpuWidget,
    FansWidget,
    GpuWidget,
    ModesWidget,
    PowerAvgWidget,
    SystemWidget,
    VitalsBox,
)


class _PollSignals(QObject):
    result = Signal(object, object)  # MetricsSnapshot, CoolingSnapshot
    mode_applied = Signal(str, object)  # mode name, error-or-None


class _PollWorker(QRunnable):
    """One sampling pass on a worker thread. Overlapping ticks are skipped."""

    def __init__(self, collector: HazyHudCollector, cc: CoolerControlClient, signals: _PollSignals) -> None:
        super().__init__()
        self._collector = collector
        self._cc = cc
        self._signals = signals

    def run(self) -> None:
        snap = self._collector.sample()
        cooling = self._cc.snapshot()
        self._signals.result.emit(snap, cooling)


class _ModeWorker(QRunnable):
    def __init__(self, cc: CoolerControlClient, uid: str, name: str, signals: _PollSignals) -> None:
        super().__init__()
        self._cc, self._uid, self._name, self._signals = cc, uid, name, signals

    def run(self) -> None:
        try:
            self._cc.set_active_mode(self._uid)
        except CCUnavailable as exc:
            self._signals.mode_applied.emit(self._name, exc)
            return
        self._signals.mode_applied.emit(self._name, None)


class Toast(QLabel):
    """A small centered overlay that fades out. Qt's answer to notify()."""

    def __init__(self, parent: QWidget) -> None:
        super().__init__(parent)
        self.setAlignment(Qt.AlignCenter)
        self.setAttribute(Qt.WA_TransparentForMouseEvents)
        self._effect = QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(self._effect)
        self._anim = QPropertyAnimation(self._effect, b"opacity", self)
        self._anim.setDuration(1400)
        self._anim.setStartValue(1.0)
        self._anim.setEndValue(0.0)
        self._anim.finished.connect(self.hide)
        self.hide()

    def show_message(self, text: str, color: str) -> None:
        self.setText(text)
        self.setStyleSheet(
            f"color: {color}; background: rgba(11,18,32,220); padding: 6px 14px;"
            f"border: 1px solid {color};"
        )
        self.adjustSize()
        parent = self.parentWidget()
        if parent is not None:
            self.move(
                (parent.width() - self.width()) // 2,
                max(8, int(parent.height() * 0.06)),
            )
        self._anim.stop()
        self._effect.setOpacity(1.0)
        self.show()
        self.raise_()
        self._anim.start()


class HazyHudWindow(QWidget):
    def __init__(self, config: Optional[SharedConfig] = None, kiosk: bool = False) -> None:
        super().__init__()
        # Closing this window must quit the app even in kiosk mode — kiosk
        # sets Qt.Tool (skip_taskbar), and Qt turns WA_QuitOnClose OFF for
        # tool windows, so Alt+F4 used to leave the process running forever
        # with no visible window.
        self.setAttribute(Qt.WA_QuitOnClose, True)
        self.cfg = config or SharedConfig()
        self._kiosk_forced = kiosk
        self.collector = HazyHudCollector()
        self.cc = self._make_cc()
        self._signals = _PollSignals(self)
        self._signals.result.connect(self._render)
        self._signals.mode_applied.connect(self._on_mode_applied)
        self._pool = QThreadPool(self)
        self._pool.setMaxThreadCount(2)
        self._poll_busy = False

        self._settings = QSettings("hazyhud", "hazyhud")
        # apply persisted double-click renames into cfg before widgets build
        for w, t in self._load_title_overrides().items():
            self.cfg.set_title(w, t)
        self._boxes: list[VitalsBox] = []
        self._modes_widget: Optional[ModesWidget] = None
        self._help_bar: Optional[HelpBar] = None
        self._preset_override: Optional[str] = None
        # the preset the CONFIG FILE currently asks for — a live 'p' override
        # survives unrelated config edits; only a real change to the file's
        # own layout.preset reasserts it (see _on_config_reload)
        self._file_preset = str(self.cfg.get("layout", "preset", default="full"))
        # launch.launch_layout picks the startup preset — unless
        # launch.restore_last_layout is on, which takes precedence
        if not self.cfg.launch_restore_last_layout:
            launch_layout = str(self.cfg.get("launch", "launch_layout", default="") or "")
            if launch_layout and launch_layout in self.cfg.preset_names():
                self._preset_override = launch_layout
        self._unknown_widgets: list[str] = []
        self._screen_hint_shown = False
        # drag-to-rearrange swaps, {widget_name: [row, col]}; kept in
        # QSettings (never written into the commented config.yaml) and
        # cleared whenever the config file is saved.
        self._drag_overrides: dict[str, list[int]] = self._load_drag_overrides()
        # corner-grip resize floors, {widget_name: [min_w, min_h]}; same
        # QSettings treatment as drag overrides.
        self._size_overrides: dict[str, list[int]] = self._load_size_overrides()

        self._root_layout = QGridLayout(self)
        self._root_layout.setContentsMargins(0, 0, 0, 0)
        self._root_layout.setSpacing(0)
        self._grid_host = QWidget()
        self._grid_host.setObjectName("root")
        self._box_grid = QGridLayout(self._grid_host)
        # free-placement surface; only used when layout.mode == "free"
        self._canvas = FreeCanvas(self.cfg, self._settings)
        self._active_host: QWidget = self._grid_host

        self.toast = Toast(self)

        self.setWindowTitle(self.cfg.window_title)
        self._rebuild_all()
        self._bind_keys()
        self._apply_window_mode()

        self.cfg.on_reload(lambda _cfg: self._on_config_reload())

        self._timer = QTimer(self)
        self._timer.timeout.connect(self._poll)
        self._timer.start(self.cfg.poll_interval_ms)
        self._poll()

    # -- construction ---------------------------------------------------------

    def _make_cc(self) -> CoolerControlClient:
        return CoolerControlClient(
            host=self.cfg.cc_host,
            port=self.cfg.cc_port,
            token=self.cfg.cc_token,
            password=self.cfg.cc_password,
            timeout=self.cfg.cc_timeout,
        )

    def _rebuild_all(self) -> None:
        """(Re)apply theme and (re)create boxes, in grid or free mode."""
        self.setStyleSheet(theme.build_qss(self.cfg))
        self.setWindowTitle(self.cfg.window_title)
        if self.cfg.layout_mode == "free":
            self._rebuild_free()
        else:
            self._rebuild_grid()

    def _rebuild_grid(self) -> None:
        """Spreadsheet layout — the default. Boxes in a QGridLayout."""
        # drop any free-canvas tiles from the other mode
        self._canvas.clear_tiles()
        # clear the box grid
        while self._box_grid.count():
            item = self._box_grid.takeAt(0)
            if item.widget() is not None:
                item.widget().deleteLater()
        self._boxes.clear()
        self._modes_widget = None

        margin = self.cfg.layout_margin
        spacing = self.cfg.layout_spacing
        self._box_grid.setContentsMargins(margin, margin, margin, margin)
        self._box_grid.setSpacing(spacing)

        columns = self.cfg.layout_columns_for(self._preset_override)
        placements = self.cfg.widget_placements(self._preset_override)
        self._apply_drag_overrides(placements)
        max_col = max(
            (spec["col"] + spec["colspan"] for spec in placements.values()), default=1
        )
        columns = max(columns, max_col)
        fill = self.cfg.layout_fill
        if fill:
            for col in range(columns):
                self._box_grid.setColumnStretch(col, 1)
        # else: no stretches — columns size to content and slack pools in the
        # absorber row/column added at the end, HA-dashboard style.

        self._unknown_widgets = []
        for name, spec in sorted(placements.items(), key=lambda kv: (kv[1]["row"], kv[1]["col"])):
            box = self._make_widget(name)
            if box is None:
                self._unknown_widgets.append(name)
                continue
            box.widget_key = name
            box.set_drag_enabled(self.cfg.layout_draggable)
            box.swapRequested.connect(self._swap_widgets)
            box.resizeDragged.connect(
                lambda w, h, key=name: self._resize_widget(key, w, h)
            )
            box.resizeFinished.connect(self._snap_after_resize)
            box.titleRenamed.connect(self._on_title_renamed)
            # per-box sizing: px floors and relative stretch weights
            if spec["min_width"]:
                box.setMinimumWidth(spec["min_width"])
            if spec["min_height"]:
                box.setMinimumHeight(spec["min_height"])
            # corner-grip floors win over config mins (most recent gesture)
            size_ov = self._size_overrides.get(name)
            if size_ov is not None:
                box.setMinimumWidth(size_ov[0])
                box.setMinimumHeight(size_ov[1])
            # hard ceilings — how you force a box to stay squatty
            if spec["max_width"]:
                box.setMaximumWidth(spec["max_width"])
            if spec["max_height"]:
                box.setMaximumHeight(spec["max_height"])
            if spec["hstretch"]:
                self._box_grid.setColumnStretch(spec["col"], spec["hstretch"])
            if spec["vstretch"]:
                self._box_grid.setRowStretch(spec["row"], spec["vstretch"])
            if fill:
                self._box_grid.addWidget(
                    box, spec["row"], spec["col"], spec["rowspan"], spec["colspan"]
                )
            else:
                # keep short boxes squatty instead of stretching to the
                # tallest box in their row
                self._box_grid.addWidget(
                    box, spec["row"], spec["col"], spec["rowspan"], spec["colspan"],
                    Qt.AlignTop,
                )
            self._boxes.append(box)
            if isinstance(box, ModesWidget):
                self._modes_widget = box

        if not fill and placements:
            # absorber row + column eat every leftover pixel so boxes stay
            # content-sized and cluster top-left instead of inflating
            max_row = max(spec["row"] + spec["rowspan"] for spec in placements.values())
            self._box_grid.setRowStretch(max_row, 1)
            self._box_grid.setColumnStretch(columns, 1)

        self._active_host = self._grid_host
        self._place_help_bar()

    def _rebuild_free(self) -> None:
        """Free-placement canvas. Tiles at absolute positions, drag to move,
        edge/corner to resize. Geometry persists per-tile; positions seed
        from where the grid would have put them the first time."""
        # drop any grid boxes from the other mode
        while self._box_grid.count():
            item = self._box_grid.takeAt(0)
            if item.widget() is not None:
                item.widget().deleteLater()
        self._canvas.clear_tiles()
        self._boxes.clear()
        self._modes_widget = None
        self._unknown_widgets = []

        # seed rects from the grid placements, scaled into the current window
        placements = self.cfg.widget_placements(self._preset_override)
        columns = max(
            self.cfg.layout_columns_for(self._preset_override),
            max((s["col"] + s["colspan"] for s in placements.values()), default=1),
        )
        max_row = max((s["row"] + s["rowspan"] for s in placements.values()), default=1)
        cw = max(self.width(), 400)
        ch = max(self.height(), 300)
        margin = self.cfg.layout_margin
        col_w = (cw - margin * 2) / max(columns, 1)
        row_h = (ch - margin * 2) / max(max_row, 1)

        for name, spec in sorted(placements.items(), key=lambda kv: (kv[1]["row"], kv[1]["col"])):
            box = self._make_widget(name)
            if box is None:
                self._unknown_widgets.append(name)
                continue
            box.widget_key = name
            # tiles carry their own frame; the box's own drag/grip is off in
            # free mode — the FreeTile owns move/resize.
            box.set_drag_enabled(False)
            box.titleRenamed.connect(self._on_title_renamed)
            seed = QRect(
                int(margin + spec["col"] * col_w),
                int(margin + spec["row"] * row_h),
                int(spec["colspan"] * col_w) - self.cfg.layout_spacing,
                int(spec["rowspan"] * row_h) - self.cfg.layout_spacing,
            )
            tile = self._canvas.add_tile(name, box, seed, grid_spec=spec)
            self._boxes.append(box)
            if isinstance(box, ModesWidget):
                self._modes_widget = box

        self._active_host = self._canvas
        self._place_help_bar()
        # No seed call here on purpose. The canvas lays itself out on its first
        # paint at real geometry and again on every resize, so there is no
        # "did we defer long enough" question to get wrong on Wayland.

    def _make_widget(self, name: str) -> Optional[VitalsBox]:
        if name == "cpu":
            return CpuWidget(self.cfg)
        if name.startswith("gpu") and name[3:].isdigit():
            return GpuWidget(self.cfg, index=int(name[3:]))
        if name == "system":
            return SystemWidget(self.cfg, version=__version__)
        if name == "aqua":
            return AquaWidget(self.cfg)
        if name == "fans":
            return FansWidget(self.cfg)
        if name == "power_avg":
            return PowerAvgWidget(self.cfg)
        if name == "mode_switcher":
            return ModesWidget(self.cfg, self._apply_mode)
        return None

    # -- drag to rearrange ---------------------------------------------------

    def _load_drag_overrides(self) -> dict[str, list[int]]:
        """{name: [row, col]} or {name: [row, col, rowspan, colspan]} — the
        4-int form is a full-rectangle swap between boxes of different spans."""
        try:
            raw = self._settings.value("layout_overrides", "")
            data = json.loads(raw) if raw else {}
            return {str(k): [int(x) for x in v] for k, v in data.items()}
        except (ValueError, TypeError, IndexError):
            return {}

    def _save_drag_overrides(self) -> None:
        self._settings.setValue("layout_overrides", json.dumps(self._drag_overrides))

    def _apply_drag_overrides(self, placements: dict) -> None:
        """Move overridden widgets to their dragged cells, skipping any move
        that would land on an occupied cell (config changed under us)."""
        occupied = {
            (r, c)
            for name, spec in placements.items()
            if name not in self._drag_overrides
            for r in range(spec["row"], spec["row"] + spec["rowspan"])
            for c in range(spec["col"], spec["col"] + spec["colspan"])
        }
        stale = []
        for name, ov in self._drag_overrides.items():
            spec = placements.get(name)
            if spec is None:
                stale.append(name)
                continue
            row, col = ov[0], ov[1]
            rowspan, colspan = (ov[2], ov[3]) if len(ov) == 4 else (spec["rowspan"], spec["colspan"])
            cells = [
                (r, c)
                for r in range(row, row + rowspan)
                for c in range(col, col + colspan)
            ]
            if any(cell in occupied for cell in cells):
                stale.append(name)  # destination taken; drop the override
                continue
            spec["row"], spec["col"] = row, col
            spec["rowspan"], spec["colspan"] = rowspan, colspan
            occupied.update(cells)
        for name in stale:
            self._drag_overrides.pop(name, None)

    def _load_size_overrides(self) -> dict[str, list[int]]:
        try:
            raw = self._settings.value("layout_size_overrides", "")
            data = json.loads(raw) if raw else {}
            return {str(k): [int(v[0]), int(v[1])] for k, v in data.items()}
        except (ValueError, TypeError, IndexError):
            return {}

    def _on_title_renamed(self, widget: str, new_title: str) -> None:
        """Persist a double-click rename. Stored in QSettings (not the config
        file, so user comments there stay intact); applied on next launch."""
        self.cfg.set_title(widget, new_title)
        renames = self._load_title_overrides()
        renames[widget] = new_title
        self._settings.setValue("title_overrides", json.dumps(renames))

    def _load_title_overrides(self) -> dict:
        try:
            raw = self._settings.value("title_overrides", "")
            return json.loads(raw) if raw else {}
        except (ValueError, TypeError):
            return {}

    def _resize_widget(self, name: str, width: int, height: int) -> None:
        """Live corner-grip resize: set a px floor on the box and remember
        it. The grid stretches around the floor; it never overlaps anything."""
        box = next((b for b in self._boxes if b.widget_key == name), None)
        if box is not None:
            box.setMinimumWidth(width)
            box.setMinimumHeight(height)
        self._size_overrides[name] = [width, height]
        self._settings.setValue("layout_size_overrides", json.dumps(self._size_overrides))

    def _snap_after_resize(self, name: str) -> None:
        """On grip release (layout.snap_resize on), snap this box's height to
        the shortest box sharing its grid row, if it's within ~24px — so you
        can size one box then line the rest of the row up to it."""
        if not self.cfg.layout_snap_resize:
            return
        placements = self.cfg.widget_placements(self._preset_override)
        self._apply_drag_overrides(placements)
        spec = placements.get(name)
        box = next((b for b in self._boxes if b.widget_key == name), None)
        if spec is None or box is None:
            return
        my_row = spec["row"]
        sibs = [
            b for b in self._boxes
            if b.widget_key != name
            and placements.get(b.widget_key, {}).get("row") == my_row
        ]
        if not sibs:
            return
        target_h = min(b.height() for b in sibs)
        if abs(box.height() - target_h) <= 24 and target_h > 0:
            self._resize_widget(name, max(box.minimumWidth(), box.width()), target_h)

    def _swap_widgets(self, target: str, source: str) -> None:
        """A box was dropped on another: swap their grid origins. The swap is
        remembered in QSettings; the config file is never rewritten."""
        placements = self.cfg.widget_placements(self._preset_override)
        self._apply_drag_overrides(placements)
        a, b = placements.get(target), placements.get(source)
        if a is None or b is None:
            return
        # full-rectangle swap: each box inherits the other's origin AND span,
        # so swapping a wide box with a narrow one never collides
        self._drag_overrides[target] = [b["row"], b["col"], b["rowspan"], b["colspan"]]
        self._drag_overrides[source] = [a["row"], a["col"], a["rowspan"], a["colspan"]]
        self._save_drag_overrides()
        self._rebuild_all()
        self._poll()
        self.toast.show_message(
            f"{source} ↔ {target}  (edit config to make permanent)",
            self.cfg.colors.get("text_label", "#2dd4bf"),
        )

    def _place_help_bar(self) -> None:
        """Slot the active host (grid or canvas) + help bar into the root
        layout per position config."""
        # detach everything from the root layout without deleting the hosts
        while self._root_layout.count():
            item = self._root_layout.takeAt(0)
            w = item.widget()
            if w is self._help_bar:
                w.deleteLater()
            elif w is not None:
                w.setParent(None)  # keep grid/canvas host alive for reuse
        # hide the inactive host so only the active one shows
        inactive = self._canvas if self._active_host is self._grid_host else self._grid_host
        inactive.hide()
        self._active_host.show()
        host = self._active_host

        self._help_bar = HelpBar(self.cfg, self)
        pos = self.cfg.help_bar_position
        edge = pos.partition("-")[0]
        # reset stretch factors before re-applying
        for i in range(3):
            self._root_layout.setRowStretch(i, 0)
            self._root_layout.setColumnStretch(i, 0)
        if pos == "left":
            self._root_layout.addWidget(self._help_bar, 0, 0)
            self._root_layout.addWidget(host, 0, 1)
            self._root_layout.setColumnStretch(1, 1)
        elif pos == "right":
            self._root_layout.addWidget(host, 0, 0)
            self._root_layout.addWidget(self._help_bar, 0, 1)
            self._root_layout.setColumnStretch(0, 1)
        else:
            bar_row, grid_row = (0, 1) if edge == "top" else (1, 0)
            self._root_layout.addWidget(host, grid_row, 0)
            self._root_layout.setRowStretch(grid_row, 1)  # host eats the space
            # the bar always fills the row; left/center/right is handled by
            # stretches inside the bar itself (see HelpBar._build)
            self._root_layout.addWidget(self._help_bar, bar_row, 0)

    # -- window modes ----------------------------------------------------------

    def _apply_window_mode(self) -> None:
        import os
        # Wayland forbids apps from positioning their own windows — the
        # compositor owns placement. setGeometry's POSITION is ignored there;
        # only the SIZE takes effect. On KDE Wayland, pin the window with a
        # Window Rule matching class "hazyhud" instead.
        is_wayland = "wayland" in os.environ.get("XDG_SESSION_TYPE", "").lower() or bool(
            os.environ.get("WAYLAND_DISPLAY")
        )
        kiosk = self.cfg.kiosk
        kiosk_enabled = self._kiosk_forced or kiosk["enabled"]
        if kiosk_enabled:
            # Qt.Tool windows stay off the taskbar and out of alt-tab —
            # right for an appliance display.
            flags = Qt.Tool if kiosk["skip_taskbar"] else Qt.Window
            if kiosk["frameless"]:
                flags |= Qt.FramelessWindowHint
            if kiosk["always_on_top"]:
                flags |= Qt.WindowStaysOnTopHint
            self.setWindowFlags(flags)
            # setWindowFlags re-derives attribute defaults from the window
            # type, and Qt.Tool gets WA_QuitOnClose=False — re-assert it or
            # closing the kiosk window leaves the process running headless
            self.setAttribute(Qt.WA_QuitOnClose, True)
            screens = QGuiApplication.screens()
            idx = min(kiosk["screen"], max(0, len(screens) - 1))
            target = screens[idx].geometry()
            if is_wayland:
                # position ignored by the compositor; match the size so a KDE
                # Window Rule ("Force geometry", or "Fullscreen") can place it
                self.resize(target.width(), target.height())
                if self._screen_hint_shown is False:
                    self._screen_hint_shown = True
            else:
                self.setGeometry(target)
            self.show()
            return

        # normal window: sized by config or content, geometry remembered
        self.setWindowFlags(Qt.Window)
        width = int(self.cfg.get("window", "width", default=0) or 0)
        height = int(self.cfg.get("window", "height", default=0) or 0)
        remember = bool(self.cfg.get("window", "remember_geometry", default=True))
        restored = False
        if remember:
            geo = self._settings.value("geometry")
            if geo is not None:
                restored = bool(self.restoreGeometry(geo))
        if not restored and (width > 0 or height > 0):
            self.resize(width or 1280, height or 720)
        self.show()

    def closeEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        # stop polling so no worker is mid-flight during teardown, and flush
        # QSettings now — a hard kill later must not lose window geometry,
        # renames, or grid drag overrides
        self._timer.stop()
        if self.cfg.get("window", "remember_geometry", default=True):
            self._settings.setValue("geometry", self.saveGeometry())
        self._settings.sync()
        super().closeEvent(event)

    # -- keys -----------------------------------------------------------------

    def _bind_keys(self) -> None:
        for seq, handler in (
            ("q", self.close),
            ("r", self._reset_minmax),
            ("m", self._focus_modes),
            ("h", self._toggle_help),
            ("e", self._open_config),
            ("p", self._cycle_preset),
            ("o", self._reset_free_layout),
        ):
            sc = QShortcut(QKeySequence(seq), self)
            sc.setContext(Qt.WindowShortcut)
            sc.activated.connect(handler)

    def _reset_free_layout(self) -> None:
        """'o' — oops. Wipe saved free-mode tile positions and re-seed them
        from the grid inside the current window. Only meaningful in free mode;
        in grid mode it's a no-op with a hint."""
        if self.cfg.layout_mode != "free":
            self.toast.show_message(
                "'o' resets tile positions (free mode only)",
                self.cfg.colors.get("text_dim", "#818cf8"),
            )
            return
        self._canvas.clear_saved_geometry()
        self._rebuild_all()
        self._poll()
        self.toast.show_message(
            "tiles reset", self.cfg.colors.get("text_normal", "#4ade80")
        )

    def _cycle_preset(self) -> None:
        """Cycle presets live. The override survives config saves — only
        editing layout.preset in the file itself reasserts the file."""
        names = self.cfg.preset_names()
        if len(names) < 2:
            return
        current = self._preset_override or str(self.cfg.get("layout", "preset", default="full"))
        try:
            idx = names.index(current)
        except ValueError:
            idx = -1
        self._preset_override = names[(idx + 1) % len(names)]
        self._rebuild_all()
        self._poll()
        self.toast.show_message(
            f"preset: {self._preset_override}", self.cfg.colors.get("text_label", "#2dd4bf")
        )

    def _toggle_help(self) -> None:
        if self._help_bar is not None:
            self._help_bar.toggle_visible()

    def _focus_modes(self) -> None:
        if self._modes_widget is not None:
            self._modes_widget.focus_list()
            self.toast.show_message(
                "mode switcher — ↑↓ select, Enter applies",
                self.cfg.colors.get("text_label", "#2dd4bf"),
            )

    def _open_config(self) -> None:
        if not self.cfg.path.exists():
            from ..config import write_default_config

            write_default_config(self.cfg.path)
        cmd = self.cfg.editor_command()
        exe = Path(cmd[0]).name.lower() if cmd else ""
        if exe in TERMINAL_EDITORS:
            # no terminal to host micro/nano/vim in (and definitely not in
            # kiosk) — edit in an overlay inside the HUD window instead
            ConfigEditorOverlay(self.cfg, self)
            return
        cmd = [*cmd, str(self.cfg.path)]
        try:
            subprocess.Popen(
                cmd,
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.toast.show_message(
                f"editing {self.cfg.path.name}", self.cfg.colors.get("text_label", "#2dd4bf")
            )
        except OSError as exc:
            self.toast.show_message(
                f"editor failed: {exc}", self.cfg.colors.get("text_crit", "#f87171")
            )

    # -- polling ---------------------------------------------------------------

    def _poll(self) -> None:
        if self.cfg.check_reload():
            return  # reload callback re-polls; skip this tick
        if self._poll_busy:
            return  # slow nvidia-smi; drop this tick rather than queue up
        self._poll_busy = True
        self._pool.start(_PollWorker(self.collector, self.cc, self._signals))

    @Slot(object, object)
    def _render(self, snap: MetricsSnapshot, cooling: CoolingSnapshot) -> None:
        self._poll_busy = False
        try:
            # cooling first: PowerAvg reads coolant before rendering its table
            for box in self._boxes:
                if hasattr(box, "update_cooling"):
                    box.update_cooling(cooling)
            for box in self._boxes:
                if hasattr(box, "update_metrics"):
                    box.update_metrics(snap)
            if (
                self.cfg.layout_mode == "grid"
                and not self.cfg.layout_fill
                and not self.cfg.layout_allow_squash
            ):
                # content-sized tiling: labels were empty at build time, so
                # grow each box's floor to its real content size now (never
                # past an explicit max ceiling). Skipped under allow_squash —
                # there the whole point is to let boxes go below content.
                for box in self._boxes:
                    hint = box.sizeHint()
                    w = min(hint.width(), box.maximumWidth())
                    h = min(hint.height(), box.maximumHeight())
                    if w > box.minimumWidth():
                        box.setMinimumWidth(w)
                    if h > box.minimumHeight():
                        box.setMinimumHeight(h)
            if self._help_bar is not None:
                if self.cfg.last_error:
                    self._help_bar.set_status(self.cfg.last_error)
                elif self._unknown_widgets or self.cfg.layout_warnings:
                    parts = []
                    if self._unknown_widgets:
                        parts.append(f"unknown widget: {', '.join(self._unknown_widgets)}")
                    parts.extend(self.cfg.layout_warnings)
                    self._help_bar.set_status("  ·  ".join(parts))
                elif not cooling.connected:
                    self._help_bar.set_status("coolercontrol offline")
                else:
                    self._help_bar.set_status(None)
        except RuntimeError:
            pass  # widgets were mid-rebuild; next tick repaints

    def _on_config_reload(self) -> None:
        # Only reassert the file's preset when the file's preset actually
        # CHANGED. Clearing the override on every save meant editing an
        # unrelated key (poll_interval_ms, a color, ...) yanked the user
        # back to the file's preset — with a different widget set, tiles
        # visibly vanished in free mode.
        file_preset = str(self.cfg.get("layout", "preset", default="full"))
        if file_preset != self._file_preset:
            self._file_preset = file_preset
            self._preset_override = None
        # drag/size overrides survive a reload — the collision guard drops
        # any that no longer fit — except where the config now sizes that
        # widget explicitly: the file reasserts itself there.
        user_widgets = self.cfg.get("layout", "widgets", default={}) or {}
        for name in list(self._size_overrides):
            entry = user_widgets.get(name)
            if isinstance(entry, dict) and ("min_width" in entry or "min_height" in entry):
                self._size_overrides.pop(name)
        self._settings.setValue("layout_size_overrides", json.dumps(self._size_overrides))
        self.cc = self._make_cc()
        self._rebuild_all()
        self._timer.start(self.cfg.poll_interval_ms)
        self._poll()

    # -- actions -----------------------------------------------------------------

    def _reset_minmax(self) -> None:
        self.collector.reset_minmax()
        self.toast.show_message(
            "min/max + averages reset", self.cfg.colors.get("text_normal", "#4ade80")
        )

    def _apply_mode(self, mode_uid: str, name: str) -> None:
        """Entry point from the mode switcher. Returns instantly; the actual
        POST runs in a worker thread so a slow daemon can't freeze the UI."""
        self._pool.start(_ModeWorker(self.cc, mode_uid, name, self._signals))

    @Slot(str, object)
    def _on_mode_applied(self, name: str, error: Optional[Exception]) -> None:
        if error is not None:
            self.toast.show_message(str(error), self.cfg.colors.get("text_crit", "#f87171"))
        else:
            self.toast.show_message(
                f"mode applied: {name}", self.cfg.colors.get("text_normal", "#4ade80")
            )
            self._poll_busy = False
            self._poll()


def run(config_path: Optional[Path] = None, kiosk: bool = False) -> int:
    import signal

    from PySide6.QtWidgets import QApplication

    app = QApplication(sys.argv[:1])
    app.setApplicationName("hazyhud")
    app.setOrganizationName("hazyhud")
    # On Wayland this becomes the app_id the compositor sees, so a KDE Window
    # Rule matching "hazyhud" can pin the window to a screen / make it
    # fullscreen — the only way to place a window under Wayland.
    app.setDesktopFileName("hazyhud")
    window = HazyHudWindow(SharedConfig(config_path), kiosk=kiosk)
    window.show()

    # Ctrl+C must exit cleanly. Inside app.exec() the interpreter only gets
    # to run a Python-level signal handler when some Python code executes —
    # unpoked, that's the next _poll tick, where KeyboardInterrupt surfaces
    # inside the slot, PySide prints it, and the loop lives on. Turn SIGINT
    # into a plain window close (which quits the app, saves geometry), and
    # run a do-nothing timer so bytecode executes regularly and the handler
    # is noticed within a quarter second even while idle.
    signal.signal(signal.SIGINT, lambda *_sig: window.close())
    sig_wakeup = QTimer(app)
    sig_wakeup.timeout.connect(lambda: None)
    sig_wakeup.start(250)

    return app.exec()
