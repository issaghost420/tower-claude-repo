"""GradientBar — the thin, discrete per-box indicator.

Design brief (from the user): one bar per box, not much taller than the
margins, a dynamic glance-indicator rather than a chart. The fill grows
left→right; its *color* is sampled from the configured gradient at the fill
fraction, so a bar sitting in the red zone reads red even when short.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QPainter, QPen
from PySide6.QtWidgets import QWidget

from ..config import SharedConfig
from . import theme


class GradientBar(QWidget):
    def __init__(self, cfg: SharedConfig, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.cfg = cfg
        self._fraction: Optional[float] = None
        self.setFixedHeight(cfg.bar_height)
        self.setMinimumWidth(40)

    def set_fraction(self, fraction: Optional[float]) -> None:
        fraction = None if fraction is None else max(0.0, min(1.0, fraction))
        if fraction != self._fraction:
            self._fraction = fraction
            self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing, False)
        w, h = self.width(), self.height()

        # track
        painter.fillRect(0, 0, w, h, QColor(self.cfg.colors.get("bar_track", "#16233b")))

        if self._fraction is not None and self._fraction > 0.0:
            fill_w = max(1, int(round(w * self._fraction)))
            painter.fillRect(0, 0, fill_w, h, theme.gradient_qcolor(self.cfg, self._fraction))
        painter.end()
