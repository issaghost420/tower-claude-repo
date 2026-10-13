"""Qt widgets for the HazyHud HUD.

Every widget is a thin renderer over the shared snapshots: it receives a
``MetricsSnapshot`` and/or ``CoolingSnapshot`` plus the live ``SharedConfig``
(for thresholds/colors/fonts) and updates pre-built QLabel cells. Widgets
hold no collector state of their own — min/max/averages live in the data
layer. On config reload the app rebuilds widgets wholesale, so fonts and
layout are read once at construction; per-tick updates only touch text and
dynamic (threshold-driven) colors.

The visual language is the v1 one: square cyan boxes, teal labels, big green
values, violet mins, amber maxes — with one thin gradient bar per box.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QMimeData, QSize, Qt, Signal
from PySide6.QtGui import QDrag
from PySide6.QtWidgets import (
    QApplication,
    QFrame,
    QGridLayout,
    QLabel,
    QLayout,
    QListWidget,
    QListWidgetItem,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from ..config import SharedConfig
from ..models import CoolingSnapshot, GpuMetrics, MetricsSnapshot
from . import theme
from .bars import GradientBar


def _fmt(value: Optional[float], decimals: int = 1) -> str:
    return f"{value:.{decimals}f}" if value is not None else "—"


def _fmt_int(value: Optional[float]) -> str:
    return f"{value:.0f}" if value is not None else "—"


def _duration(seconds: float) -> str:
    seconds = int(seconds)
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m, _ = divmod(rem, 60)
    if d:
        return f"{d}d{h:02d}h{m:02d}m"
    return f"{h:02d}h {m:02d}m"


#: mime type used for box-rearrange drags (internal to the window)
DRAG_MIME = "application/x-hazyhud-widget"


class VitalsBox(QFrame):
    """Base: a bordered box with a title, a content grid, and one bar.

    Drag-to-rearrange: pressing the *title bar* and dragging onto another
    box emits ``swapRequested(target, source)``; the window swaps their grid
    cells. Dragging is opt-out via ``layout.draggable: false``.
    """

    widget_key: str = ""

    #: emitted when another box is dropped on this one (target, source)
    swapRequested = Signal(str, str)
    #: emitted continuously while the corner grip is dragged (w, h px)
    resizeDragged = Signal(int, int)
    #: emitted once when a grip resize ends, for snap-to-row (widget_key)
    resizeFinished = Signal(str)
    #: emitted when the user renames the box via double-click (widget_key, new)
    titleRenamed = Signal(str, str)

    #: corner grip hit area, px
    GRIP = 18

    def __init__(self, cfg: SharedConfig, title: str, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("box")
        self.cfg = cfg
        self._drag_enabled = False
        self._drag_start = None
        self._resize_origin = None  # (mouse global pos, start size) while gripping
        self._allow_squash = cfg.layout_allow_squash
        self._min_box = cfg.min_box_size
        # apply a per-tile border override via an inline stylesheet on top of
        # the global QSS (QSS object selectors can't target per-instance)
        bw = cfg.border_width_for(self.widget_key)
        if bw != cfg.border_width:
            self.setStyleSheet(
                f"QFrame#box {{ border: {bw}px solid {cfg.colors.get('border', '#38bdf8')}; }}"
            )
        # renamed title (config `titles`/`tiles.<w>.title`, or default)
        self._title_text = cfg.title_for(self.widget_key, title)
        pad_x, pad_y = cfg.box_padding

        outer = QVBoxLayout(self)
        outer.setContentsMargins(pad_x, pad_y, pad_x, pad_y)
        outer.setSpacing(0)
        if self._allow_squash:
            # Stop the layout from forcing the box up to its content size —
            # this is what lets a box clip/overlap its own labels.
            outer.setSizeConstraint(QLayout.SetNoConstraint)
            self.setMinimumSize(0, 0)

        self.bar: Optional[GradientBar] = None
        self.bar_metric = cfg.bar_source(self.widget_key)
        if cfg.bars_enabled and self.bar_metric:
            self.bar = GradientBar(cfg)
            if cfg.bar_position == "top":
                outer.addWidget(self.bar)
                outer.addSpacing(pad_y // 2)

        self.title_label = self._mklabel("boxTitle", "title", self._title_text)
        # The title lives in the box's vertical layout, ABOVE the content
        # grid — never inside it. A grid title needs a column span to be
        # full-width, and a wide span is poison: QGridLayout charges the
        # horizontal spacing for *every* spanned column, so spanning "all 99"
        # columns added ~1.2k px of phantom width to every box and crushed
        # the real content columns to slivers (the "widen the window until
        # the data pokes out of the far left" bug). In the vbox the title is
        # full-width by construction, and the theme's border-bottom still
        # draws the underline. Content rows in the grid are unchanged (row 1
        # headers, row 2+ data); the now-empty grid row 0 costs nothing —
        # Qt charges no spacing for a row no item occupies.
        outer.addWidget(self.title_label, 0, Qt.AlignLeft | Qt.AlignVCenter)
        outer.addSpacing(max(2, cfg.row_spacing))

        self.grid = QGridLayout()
        self.grid.setVerticalSpacing(cfg.row_spacing)
        self.grid.setHorizontalSpacing(12)
        self.grid.setColumnStretch(1, 1)  # value column absorbs slack
        outer.addLayout(self.grid, stretch=1)

        if self.bar is not None and cfg.bar_position == "bottom":
            outer.addSpacing(max(2, pad_y // 2))
            outer.addWidget(self.bar)

        self.title_label.installEventFilter(self)
        self.setAcceptDrops(True)
        self._has_headers = False

    def minimumSizeHint(self) -> QSize:  # noqa: N802 (Qt naming)
        # In squash mode the box reports the configured min_box as its floor
        # instead of whatever its content wants, so it can shrink past it.
        if self._allow_squash:
            return QSize(self._min_box[0], self._min_box[1])
        return super().minimumSizeHint()

    def showEvent(self, event) -> None:  # noqa: N802
        super().showEvent(event)

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        if self.cfg.downscale_font_for(self.widget_key):
            self._apply_font_scale()

    def _apply_font_scale(self) -> None:
        """When the tile is smaller than its content wants, scale every label
        font down to fit. Restores toward 1.0 as the tile grows. Only active
        when downscale_font is on."""
        hint = super().minimumSizeHint()
        if hint.width() <= 0 or hint.height() <= 0:
            return
        fw = self.width() / hint.width()
        fh = self.height() / hint.height()
        scale = max(0.4, min(1.0, min(fw, fh)))
        if abs(scale - getattr(self, "_font_scale", 1.0)) < 0.03:
            return
        self._font_scale = scale
        for lab in self.findChildren(QLabel):
            cls = lab.property("fontClass")
            if not cls:
                continue
            spec = self.cfg.font_class(cls)
            f = lab.font()
            f.setPixelSize(max(6, int(spec["size"] * scale)))
            lab.setFont(f)

    # -- drag to rearrange ---------------------------------------------------

    def set_drag_enabled(self, enabled: bool) -> None:
        self._drag_enabled = enabled
        self.title_label.setCursor(Qt.OpenHandCursor if enabled else Qt.ArrowCursor)
        self.setMouseTracking(enabled)  # hover cursor over the grip

    def eventFilter(self, obj, event) -> bool:  # noqa: N802 (Qt naming)
        if obj is self.title_label:
            # double-click the title to rename it inline, in any mode
            if event.type() == event.Type.MouseButtonDblClick and event.button() == Qt.LeftButton:
                self._begin_rename()
                return True
            if self._drag_enabled:
                if event.type() == event.Type.MouseButtonPress and event.button() == Qt.LeftButton:
                    self._drag_start = event.position().toPoint()
                elif event.type() == event.Type.MouseMove and self._drag_start is not None:
                    dist = (event.position().toPoint() - self._drag_start).manhattanLength()
                    if dist >= QApplication.startDragDistance():
                        self._drag_start = None
                        self._start_drag()
                elif event.type() == event.Type.MouseButtonRelease:
                    self._drag_start = None
        return super().eventFilter(obj, event)

    def _begin_rename(self) -> None:
        """Swap the title label for a line edit; commit on Enter/focus-out."""
        from PySide6.QtWidgets import QLineEdit

        # Seed the editor with what's ON SCREEN, not the stale default —
        # auto-named boxes (GPU 0 (RTX 5090)) update the label from live
        # hardware data, and seeding from _title_text pre-filled the editor
        # with bare "GPU 0", so a rename silently amputated the device name.
        current = self.title_label.text() or self._title_text
        editor = QLineEdit(current, self)
        editor.setObjectName("titleEdit")
        editor.setFont(theme.make_font(self.cfg, "title"))
        editor.selectAll()
        # place it over the title
        editor.setGeometry(self.title_label.geometry())
        editor.show()
        editor.setFocus()

        def commit() -> None:
            new = editor.text().strip() or current
            self._title_text = new
            self.title_label.setText(new)
            self.titleRenamed.emit(self.widget_key, new)
            editor.deleteLater()

        editor.returnPressed.connect(commit)
        editor.editingFinished.connect(commit)

    def _start_drag(self) -> None:
        mime = QMimeData()
        mime.setData(DRAG_MIME, self.widget_key.encode("utf-8"))
        drag = QDrag(self)
        drag.setMimeData(mime)
        # ghost of the box at half size so you can see what you're moving
        pix = self.grab()
        if pix.width() > 320:
            pix = pix.scaledToWidth(320, Qt.SmoothTransformation)
        drag.setPixmap(pix)
        drag.setHotSpot(pix.rect().center())
        self.title_label.setCursor(Qt.ClosedHandCursor)
        drag.exec(Qt.MoveAction)
        if self._drag_enabled:
            self.title_label.setCursor(Qt.OpenHandCursor)

    def dragEnterEvent(self, event) -> None:  # noqa: N802
        mime = event.mimeData()
        src = bytes(mime.data(DRAG_MIME)).decode("utf-8") if mime.hasFormat(DRAG_MIME) else ""
        if src and src != self.widget_key:
            event.acceptProposedAction()
            self._set_drop_highlight(True)

    def dragLeaveEvent(self, event) -> None:  # noqa: N802
        self._set_drop_highlight(False)

    def dropEvent(self, event) -> None:  # noqa: N802
        self._set_drop_highlight(False)
        src = bytes(event.mimeData().data(DRAG_MIME)).decode("utf-8")
        if src and src != self.widget_key:
            event.acceptProposedAction()
            self.swapRequested.emit(self.widget_key, src)

    def _set_drop_highlight(self, on: bool) -> None:
        self.setProperty("dropTarget", "true" if on else "false")
        self.style().unpolish(self)
        self.style().polish(self)

    # -- corner-grip resize ---------------------------------------------------

    def _in_grip(self, pos) -> bool:
        return (
            self._drag_enabled
            and pos.x() >= self.width() - self.GRIP
            and pos.y() >= self.height() - self.GRIP
        )

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if event.button() == Qt.LeftButton and self._in_grip(event.position()):
            self._resize_origin = (event.globalPosition().toPoint(), self.size())
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        if self._resize_origin is not None:
            origin, start = self._resize_origin
            delta = event.globalPosition().toPoint() - origin
            # Grip floor comes from layout.min_box, but never below a grabbable
            # size or you can't get the grip back to enlarge it.
            floor_w = max(self._min_box[0], 24)
            floor_h = max(self._min_box[1], 24)
            self.resizeDragged.emit(
                max(floor_w, start.width() + delta.x()),
                max(floor_h, start.height() + delta.y()),
            )
            event.accept()
            return
        if self._drag_enabled:
            self.setCursor(Qt.SizeFDiagCursor if self._in_grip(event.position()) else Qt.ArrowCursor)
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        was_resizing = self._resize_origin is not None
        self._resize_origin = None
        self.unsetCursor()
        super().mouseReleaseEvent(event)
        if was_resizing:
            self.resizeFinished.emit(self.widget_key)

    def paintEvent(self, event) -> None:  # noqa: N802
        super().paintEvent(event)
        if not self._drag_enabled:
            return
        from PySide6.QtGui import QPainter, QPen, QColor
        color = QColor(self.cfg.colors.get("border", "#38bdf8"))
        color.setAlpha(120)
        p = QPainter(self)
        p.setPen(QPen(color, 1))
        w, h = self.width(), self.height()
        for i in (2, 6, 10):  # three diagonal ticks, classic grip
            p.drawLine(w - i - 4, h - 3, w - 3, h - i - 4)
        p.end()

    # -- cell factory ------------------------------------------------------

    def _mklabel(self, obj_name: str, font_cls: str, text: str = "") -> QLabel:
        lab = QLabel(text)
        lab.setObjectName(obj_name)
        lab.setProperty("fontClass", font_cls)  # used by downscale_font
        lab.setFont(theme.make_font(self.cfg, font_cls))
        return lab

    def _put(self, row: int, col: int, lab: QLabel, align=Qt.AlignRight | Qt.AlignVCenter) -> QLabel:
        self.grid.addWidget(lab, row, col, align)
        return lab

    def _headers(self, *names: str) -> None:
        """Column headers sit in row 1, beneath the full-width title (row 0).
        The title's border-bottom draws the underline."""
        self._has_headers = True
        for i, name in enumerate(names, start=1):
            self._put(1, i, self._mklabel("colHeader", "header", name))

    def _set_color(self, lab: QLabel, color: str) -> None:
        lab.setStyleSheet(f"color: {color};")

    def _spread_rows(self, first: int, last: int) -> None:
        """Give content rows equal vertical stretch so boxes fill their cell
        instead of packing to the top when the window is tall.
        Disabled by layout.spread_rows: false — rows pack single-line."""
        if not self.cfg.layout_spread_rows:
            return
        for r in range(first, last + 1):
            self.grid.setRowStretch(r, 1)

    def _set_bar(self, value: Optional[float]) -> None:
        if self.bar is not None and self.bar_metric:
            self.bar.set_fraction(self.cfg.bar_fraction(self.bar_metric, value))

    def _dim(self, lab: QLabel, text: str) -> None:
        lab.setText(text)
        self._set_color(lab, self.cfg.colors.get("text_dim", "#818cf8"))

    def _maxed(self, lab: QLabel, text: str) -> None:
        lab.setText(text)
        self._set_color(lab, self.cfg.colors.get("text_max", "#fbbf24"))

    def _valued(self, lab: QLabel, metric: str, value: Optional[float], text: str) -> None:
        lab.setText(text)
        self._set_color(lab, theme.state_color(self.cfg, metric, value))

    def _normal(self, lab: QLabel, text: str) -> None:
        lab.setText(text)
        self._set_color(lab, self.cfg.colors.get("text_normal", "#4ade80"))


class CpuWidget(VitalsBox):
    widget_key = "cpu"

    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "CPU", **kwargs)
        self._headers("Current", "Min", "Max")
        self._rows: list[tuple[str, QLabel, QLabel, QLabel, int]] = []
        for i, (label, metric) in enumerate(
            (("Temp °C", "cpu_temp"), ("Load %", "cpu_load"), ("Power W", "cpu_power")),
            start=2,
        ):
            self._put(i, 0, self._mklabel("rowLabel", "label", label), Qt.AlignLeft | Qt.AlignVCenter)
            cur = self._put(i, 1, self._mklabel("value", "value"))
            mn = self._put(i, 2, self._mklabel("dimText", "small"))
            mx = self._put(i, 3, self._mklabel("dimText", "small"))
            self._rows.append((metric, cur, mn, mx, 1))
        self._spread_rows(2, 4)

    def update_metrics(self, snap: MetricsSnapshot) -> None:
        c = snap.cpu
        triples = (
            (c.temp, c.min_temp, c.max_temp),
            (c.load, c.min_load, c.max_load),
            (c.power, c.min_power, c.max_power),
        )
        for (metric, cur_l, mn_l, mx_l, dec), (cur, mn, mx) in zip(self._rows, triples):
            self._valued(cur_l, metric, cur, _fmt(cur, dec))
            self._dim(mn_l, _fmt(mn, dec))
            self._maxed(mx_l, _fmt(mx, dec))
        self._set_bar({"cpu_temp": c.temp, "cpu_load": c.load, "cpu_power": c.power}.get(self.bar_metric or ""))


class GpuWidget(VitalsBox):
    widget_key = "gpu"

    def __init__(self, cfg: SharedConfig, index: int, **kwargs) -> None:
        self.index = index
        self.widget_key = f"gpu{index}"
        super().__init__(cfg, f"GPU {index}", **kwargs)
        self._headers("Current", "Min", "Max")
        self._rows: list[tuple[str, QLabel, QLabel, QLabel]] = []
        for i, (label, metric) in enumerate(
            (("Temp °C", "gpu_temp"), ("Load %", "gpu_load"), ("Power W", "gpu_power")),
            start=2,
        ):
            self._put(i, 0, self._mklabel("rowLabel", "label", label), Qt.AlignLeft | Qt.AlignVCenter)
            cur = self._put(i, 1, self._mklabel("value", "value"))
            mn = self._put(i, 2, self._mklabel("dimText", "small"))
            mx = self._put(i, 3, self._mklabel("dimText", "small"))
            self._rows.append((metric, cur, mn, mx))
        self._put(5, 0, self._mklabel("rowLabel", "label", "VRAM"), Qt.AlignLeft | Qt.AlignVCenter)
        self.vram = self._mklabel("value", "small")
        self.grid.addWidget(self.vram, 5, 1, 1, 3, Qt.AlignHCenter | Qt.AlignVCenter)
        self._spread_rows(2, 5)

    def update_metrics(self, snap: MetricsSnapshot) -> None:
        g: Optional[GpuMetrics] = next((x for x in snap.gpus if x.index == self.index), None)
        # only auto-name the box if the user hasn't renamed it
        renamed = self.cfg.title_for(self.widget_key, "") != ""
        if g is None:
            if not renamed:
                self.title_label.setText(f"GPU {self.index}")
            self._dim(self._rows[0][1], "not detected")
            return
        if not renamed:
            short = g.name.replace("NVIDIA", "").replace("GeForce", "").strip()
            auto = f"GPU {g.index} ({short})" if short else f"GPU {g.index}"
            self.title_label.setText(auto)
            # keep _title_text in sync with the live label so the rename
            # editor (and its empty-input fallback) starts from the full
            # auto-name, not the bare "GPU <n>" constructor default
            self._title_text = auto
        triples = (
            (g.temp, g.min_temp, g.max_temp),
            (g.load, g.min_load, g.max_load),
            (g.power, g.min_power, g.max_power),
        )
        for (metric, cur_l, mn_l, mx_l), (cur, mn, mx) in zip(self._rows, triples):
            self._valued(cur_l, metric, cur, _fmt(cur))
            self._dim(mn_l, _fmt(mn))
            self._maxed(mx_l, _fmt(mx))
        vram = f"{_fmt(g.vram_used)}/{_fmt(g.vram_total, 0)} GB"
        self._normal(self.vram, vram)
        self._set_bar(
            {"gpu_temp": g.temp, "gpu_load": g.load, "gpu_power": g.power}.get(self.bar_metric or "")
        )


class SystemWidget(VitalsBox):
    """RAM (+ DDR5 temp), disk R/W, uptime, session — the v1 'System' panel.

    The header carries the box's party trick from v1.0: total current draw
    (CPU + all GPUs) in crit red, so 'how hard is the tower working right
    now' is readable from across the room.
    """

    widget_key = "system"

    def __init__(self, cfg: SharedConfig, version: str = "", **kwargs) -> None:
        super().__init__(cfg, "System", **kwargs)
        self._version = version
        # Header extras live on grid row 1, the same row the other boxes use
        # for column headers. The title isn't in the grid at all any more —
        # it sits above it in the box layout, so row 0 stays empty.
        self.total_power = self._put(1, 1, self._mklabel("value", "title"))
        self._put(1, 3, self._mklabel("dimText", "small", f"hazyhud {version}".strip()))

        self._put(2, 0, self._mklabel("rowLabel", "label", "RAM"), Qt.AlignLeft | Qt.AlignVCenter)
        self.ram_val = self._put(2, 1, self._mklabel("value", "value"))
        self.ram_pct = self._put(2, 2, self._mklabel("dimText", "small"))
        self.ram_tmp = self._put(2, 3, self._mklabel("dimText", "small"))

        self._put(3, 0, self._mklabel("rowLabel", "label", "Read"), Qt.AlignLeft | Qt.AlignVCenter)
        self.read_val = self._put(3, 1, self._mklabel("value", "value"))
        self.uptime = self._mklabel("dimText", "small")
        self.grid.addWidget(self.uptime, 3, 2, 1, 2, Qt.AlignRight | Qt.AlignVCenter)

        self._put(4, 0, self._mklabel("rowLabel", "label", "Write"), Qt.AlignLeft | Qt.AlignVCenter)
        self.write_val = self._put(4, 1, self._mklabel("value", "value"))
        self.session = self._mklabel("dimText", "small")
        self.grid.addWidget(self.session, 4, 2, 1, 2, Qt.AlignRight | Qt.AlignVCenter)
        self._spread_rows(2, 4)

    def update_metrics(self, snap: MetricsSnapshot) -> None:
        r, dk, sys = snap.ram, snap.disk, snap.system
        total = sum(v for v in [snap.cpu.power, *(g.power for g in snap.gpus)] if v is not None)
        self._valued(self.total_power, "total_power", total, f"{total:.0f} W")
        self._valued(
            self.ram_val, "ram_percent", r.percent, f"{_fmt(r.used_gb)}/{_fmt(r.total_gb, 0)} GB"
        )
        self._dim(self.ram_pct, f"{_fmt(r.percent, 0)}%")
        self._dim(self.ram_tmp, f"DDR5 {_fmt(r.temp)}°C" if r.temp is not None else "")
        self._normal(self.read_val, f"{_fmt(dk.read_mbs)} MB/s")
        self._normal(self.write_val, f"{_fmt(dk.write_mbs)} MB/s")
        self._normal(self.uptime, f"Uptime  {_duration(sys.uptime_s)}")
        self._dim(self.session, f"Session {_duration(sys.session_s)}")
        self._set_bar(r.percent)


class AquaWidget(VitalsBox):
    """Coolant + loop temps from the Octo (or whichever CC device is matched).

    Shows every temp sensor the matched device reports — the 3 Octo temp
    sensors included — with coolant threshold coloring.
    """

    widget_key = "aqua"
    MAX_SENSORS = 6

    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "Coolant", **kwargs)
        # row 0 is empty (the title lives above the grid); the device name
        # goes on row 1 with the other boxes' column headers.
        self.device_label = self._put(1, 1, self._mklabel("dimText", "small"))
        self._rows: list[tuple[QLabel, QLabel]] = []
        for i in range(2, self.MAX_SENSORS + 2):
            lab = self._put(i, 0, self._mklabel("rowLabel", "label"), Qt.AlignLeft | Qt.AlignVCenter)
            val = self._put(i, 1, self._mklabel("value", "value"))
            self._rows.append((lab, val))
        self._spread_rows(2, self.MAX_SENSORS + 1)

    def update_cooling(self, snap: CoolingSnapshot) -> None:
        match = self.cfg.get("coolercontrol", "aqua_device_match", default="octo")
        temps = [
            t
            for t in snap.temps
            if snap.connected and (not match or match.lower() in t.device_name.lower())
        ]
        if not snap.connected:
            temps = []
        spread = self.cfg.layout_spread_rows
        for i, (lab, val) in enumerate(self._rows):
            grid_row = i + 2
            if i < len(temps):
                t = temps[i]
                lab.show(); val.show()
                lab.setText(t.label)
                self._valued(val, "water_temp", t.temp, f"{t.temp:.1f} °C")
                self.grid.setRowStretch(grid_row, 1 if spread else 0)
                if i == 0:
                    self._dim(self.device_label, t.device_name[:22])
            elif i == 0 and not snap.connected:
                lab.show(); val.show()
                lab.setText("")
                self._dim(val, "daemon offline")
                self.grid.setRowStretch(grid_row, 0)
            else:
                # Hide unused rows entirely so the box collapses to the number
                # of sensors actually present, not the MAX_SENSORS reservation.
                lab.hide(); val.hide()
                self.grid.setRowStretch(grid_row, 0)
        if not snap.connected:
            self._dim(self.device_label, "")
        self._set_bar(temps[0].temp if temps else None)


class FansWidget(VitalsBox):
    """Fan grid: label | duty% | rpm, two channels per row, one group bar."""

    widget_key = "fans"
    MAX_ROWS = 6  # 12 channels visible; Octo's 8 fit with room for flow/pump

    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "Fans", **kwargs)
        self.grid.setColumnStretch(0, 1)   # left labels take the slack
        self.grid.setColumnStretch(4, 1)   # right labels take the slack
        self.grid.setColumnMinimumWidth(3, 28)  # breathing room between groups
        self._cells: list[tuple[QLabel, QLabel, QLabel]] = []
        for i in range(self.MAX_ROWS * 2):
            row = i % self.MAX_ROWS
            half = i // self.MAX_ROWS
            base_col = half * 4
            lab = self._put(row + 1, base_col, self._mklabel("rowLabel", "label"),
                            Qt.AlignLeft | Qt.AlignVCenter)
            duty = self._put(row + 1, base_col + 1, self._mklabel("value", "label"))
            rpm = self._put(row + 1, base_col + 2, self._mklabel("dimText", "small"))
            self._cells.append((lab, duty, rpm))
        self._spread_rows(1, self.MAX_ROWS)

    def update_cooling(self, snap: CoolingSnapshot) -> None:
        match = self.cfg.get("coolercontrol", "fan_device_match", default="")
        fans = [
            f
            for f in snap.fans
            if snap.connected and (not match or match.lower() in f.device_name.lower())
        ]
        spread = self.cfg.layout_spread_rows
        # column-major fill: fans 1..N/2 down the left, rest down the right
        duties: list[float] = []
        for i, (lab, duty_l, rpm_l) in enumerate(self._cells):
            if i < len(fans):
                f = fans[i]
                lab.show(); duty_l.show(); rpm_l.show()
                lab.setText(f.label)
                self._normal(duty_l, _fmt_int(f.duty))
                self._dim(rpm_l, _fmt_int(f.rpm))
                if f.duty is not None:
                    duties.append(float(f.duty))
            else:
                lab.hide(); duty_l.hide(); rpm_l.hide()
        # collapse any grid row whose left AND right cell are both unused
        for r in range(self.MAX_ROWS):
            left, right = r, r + self.MAX_ROWS
            used = left < len(fans) or right < len(fans)
            self.grid.setRowStretch(r + 1, 1 if (used and spread) else 0)
        if not snap.connected and self._cells:
            self._cells[0][0].show()
            self._cells[0][0].setText("")
            self._cells[0][1].show()
            self._dim(self._cells[0][1], "daemon offline")
            self.grid.setRowStretch(1, 0)
        self._set_bar(sum(duties) / len(duties) if duties else None)


class PowerAvgWidget(VitalsBox):
    """HW | avg | 15m — lifetime vs rolling-15m power, with warmup honesty."""

    widget_key = "power_avg"
    MAX_ROWS = 4  # CPU + 2 GPUs + spare (H₂O lives in Coolant, not here)

    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "Power", **kwargs)
        self._headers("avg", "15m")
        self.grid.setColumnStretch(2, 1)
        self._rows: list[tuple[QLabel, QLabel, QLabel]] = []
        for i in range(2, self.MAX_ROWS + 2):
            lab = self._put(i, 0, self._mklabel("rowLabel", "label"), Qt.AlignLeft | Qt.AlignVCenter)
            avg = self._put(i, 1, self._mklabel("dimText", "label"))
            m15 = self._put(i, 2, self._mklabel("value", "value"))
            self._rows.append((lab, avg, m15))
        self._spread_rows(2, self.MAX_ROWS + 1)
        self._total_power: Optional[float] = None

    def update_cooling(self, snap: CoolingSnapshot) -> None:
        # H₂O moved to the Coolant box — Power is watts only now.
        return

    def update_metrics(self, snap: MetricsSnapshot) -> None:
        powers = [snap.cpu.power, *(g.power for g in snap.gpus)]
        self._total_power = sum(p for p in powers if p is not None)

        rows: list[tuple[str, Optional[float], Optional[float], float, str]] = [
            ("CPU W", snap.cpu.avg_power, snap.cpu.avg_power_15m,
             snap.cpu.avg_15m_coverage, "cpu_power")
        ]
        for g in snap.gpus:
            rows.append((f"GPU {g.index} W", g.avg_power, g.avg_power_15m,
                         g.avg_15m_coverage, "gpu_power"))

        for i, (lab, avg_l, m15_l) in enumerate(self._rows):
            if i >= len(rows):
                lab.setText("")
                avg_l.setText("")
                m15_l.setText("")
                continue
            label, avg, avg15, coverage, metric = rows[i]
            lab.setText(label)
            if label == "H₂O °C":
                avg_l.setText("")
                self._valued(m15_l, metric, self._coolant, _fmt(self._coolant))
                continue
            warm = coverage >= 0.98
            avg15_text = _fmt(avg15, 0) if warm else (
                f"~{_fmt(avg15, 0)}" if avg15 is not None else "—")
            self._dim(avg_l, _fmt(avg, 0))
            self._valued(m15_l, metric, avg15, avg15_text)
        self._set_bar(self._total_power)


class ModesWidget(VitalsBox):
    """Cooling modes from CoolerControl. Click or Enter applies the selection.

    ``apply_callback(uid, name)`` must be non-blocking — the app runs the
    actual daemon POST in a worker thread. The list always shows a visible
    selection and the active mode is marked, so applying a mode is
    discoverable and confirmed — the 'm does nothing' bug from the TUI.
    """

    widget_key = "mode_switcher"

    def __init__(self, cfg: SharedConfig, apply_callback, **kwargs) -> None:
        super().__init__(cfg, "Cooling Modes", **kwargs)
        self._apply = apply_callback
        self._modes = []
        self._active_uid: Optional[str] = None

        self.list = QListWidget()
        self.list.setObjectName("modes")
        # let box-rearrange drags fall through to the box frame
        self.list.setAcceptDrops(False)
        self.list.setDragDropMode(QListWidget.DragDropMode.NoDragDrop)
        self.list.setFont(theme.make_font(cfg, "label"))
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.list.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        if self._allow_squash:
            # QListWidget's own sizeHint would otherwise floor the box at the
            # height of all its rows; Ignored lets it shrink and scroll.
            self.list.setMinimumSize(0, 0)
            self.list.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Ignored)
        self.grid.addWidget(self.list, 1, 0, 1, 4)
        self.grid.setRowStretch(1, 1)

        self.list.itemActivated.connect(self._on_chosen)   # Enter / double-click
        self.list.itemClicked.connect(self._on_chosen)     # single click applies

    def focus_list(self) -> None:
        self.list.setFocus(Qt.OtherFocusReason)
        if self.list.currentRow() < 0 and self.list.count():
            self.list.setCurrentRow(0)

    def _on_chosen(self, item: QListWidgetItem) -> None:
        uid = item.data(Qt.UserRole)
        mode = next((m for m in self._modes if m.uid == uid), None)
        if mode is not None:
            self._apply(mode.uid, mode.name)

    def update_cooling(self, snap: CoolingSnapshot) -> None:
        colors = self.cfg.colors
        self._modes = list(snap.modes)
        self._active_uid = snap.active_mode_uid

        current_row = self.list.currentRow()
        self.list.clear()
        if not snap.connected:
            item = QListWidgetItem("daemon offline")
            item.setFlags(Qt.NoItemFlags)
            self.list.addItem(item)
            return
        if not self._modes:
            item = QListWidgetItem("no modes saved in CoolerControl")
            item.setFlags(Qt.NoItemFlags)
            self.list.addItem(item)
            return
        active_row = 0
        for i, m in enumerate(self._modes):
            active = m.uid == snap.active_mode_uid
            item = QListWidgetItem(f"▸ {m.name}" if active else f"   {m.name}")
            item.setData(Qt.UserRole, m.uid)
            self.list.addItem(item)
            if active:
                active_row = i
        # selection follows the active mode unless the user is browsing
        self.list.setCurrentRow(current_row if 0 <= current_row < self.list.count() else active_row)
        self._paint_items()

    def _paint_items(self) -> None:
        from PySide6.QtGui import QColor

        colors = self.cfg.colors
        for i, m in enumerate(self._modes):
            item = self.list.item(i)
            if item is None:
                continue
            if m.uid == self._active_uid:
                item.setForeground(QColor(colors.get("text_normal", "#4ade80")))
            else:
                item.setForeground(QColor(colors.get("text_dim", "#818cf8")))
