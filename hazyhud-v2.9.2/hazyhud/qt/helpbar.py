"""HelpBar — the keybinding hint strip.

Hideable (h key or config), and positionable in 8 orientations:
bottom/top × left/center/right, plus vertical strips on the left/right
window edges. Status messages (config errors, daemon offline) surface here
in crit color, replacing the hints until the condition clears.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QSize, Qt
from PySide6.QtWidgets import QHBoxLayout, QLabel, QVBoxLayout, QWidget

from ..config import SharedConfig
from . import theme


class _HintLabel(QLabel):
    """A label whose minimum width is zero, no matter its content.

    QLabel's minimumSizeHint is content-driven and is NOT lowered by
    setMinimumWidth(0). 8 hints at natural width are ~1100px, and that
    used to become the window's minimum width — in free mode the canvas
    clamp math then worked against a size the user never asked for.
    Reporting a zero-width minimum lets the hints clip when the window
    is narrow ('h' hides the bar entirely), while the default Preferred
    policy still hands every hint its full natural width whenever it
    fits. (QSizePolicy.Ignored was tried instead: it also zeroes the
    *preferred* size, so the bar's stretches ate everything and the
    hints vanished at ANY width.)"""

    def minimumSizeHint(self) -> QSize:
        s = super().minimumSizeHint()
        return QSize(0, s.height())


GRID_HINTS = [
    ("q", "quit"),
    ("r", "reset min/max"),
    ("m", "modes"),
    ("h", "help bar"),
    ("e", "edit config"),
    ("p", "presets"),
    ("drag", "swap boxes"),
    ("grip", "resize box"),
]

FREE_HINTS = [
    ("q", "quit"),
    ("r", "reset min/max"),
    ("m", "modes"),
    ("h", "help bar"),
    ("e", "edit config"),
    ("drag", "move tile"),
    ("edge", "resize tile"),
    ("o", "reset tiles"),
]

VERTICAL_POSITIONS = {"left", "right"}


class HelpBar(QWidget):
    def __init__(self, cfg: SharedConfig, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.cfg = cfg
        self._status: Optional[str] = None
        self._build()

    def _build(self) -> None:
        vertical = self.cfg.help_bar_position in VERTICAL_POSITIONS
        layout = QVBoxLayout(self) if vertical else QHBoxLayout(self)
        layout.setContentsMargins(6, 2, 6, 2)
        layout.setSpacing(14 if not vertical else 6)

        self._labels: list[QLabel] = []
        font = theme.make_font(self.cfg, "help")
        key_color = self.cfg.colors.get("help_key", "#fbbf24")
        text_color = self.cfg.colors.get("help_text", "#64748b")

        # Alignment is done with stretches INSIDE the bar, and the bar itself
        # always stretches to fill its cell. (It used to be aligned as a whole
        # from the outside, which sized it to its content sizeHint — fine until
        # the labels become shrinkable, when that collapses the bar to zero.)
        align = self.cfg.help_bar_position.partition("-")[2] or "center"
        if not vertical and align in ("center", "right"):
            layout.addStretch(1)

        hints = FREE_HINTS if self.cfg.layout_mode == "free" else GRID_HINTS
        for key, action in hints:
            lab = _HintLabel(f'<span style="color:{key_color};"><b>{key}</b></span>'
                             f' <span style="color:{text_color};">{action}</span>')
            lab.setFont(font)
            lab.setTextFormat(Qt.RichText)
            layout.addWidget(lab)
            self._labels.append(lab)
        if not vertical and align != "right":
            layout.addStretch(1)

        self._status_label = _HintLabel("")
        self._status_label.setFont(font)
        self._status_label.hide()
        layout.addWidget(self._status_label)

        if vertical:
            for lab in self._labels:
                lab.setAlignment(Qt.AlignHCenter)
        self.setVisible(self.cfg.help_bar_visible)

    @property
    def is_vertical(self) -> bool:
        return self.cfg.help_bar_position in VERTICAL_POSITIONS

    def set_status(self, message: Optional[str]) -> None:
        """Transient status (config error, daemon offline). None clears it."""
        crit = self.cfg.colors.get("text_crit", "#f87171")
        if message:
            self._status_label.setText(message)
            self._status_label.setStyleSheet(f"color: {crit};")
            self._status_label.show()
        else:
            self._status_label.hide()

    def toggle_visible(self) -> bool:
        self.setVisible(not self.isVisible())
        return self.isVisible()
