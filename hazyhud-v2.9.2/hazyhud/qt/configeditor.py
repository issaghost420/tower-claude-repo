"""In-window config editor overlay.

The 'e' key normally hands config.yaml to an external editor. When the
configured editor is a TERMINAL editor (micro, nano, vim...) there is no
terminal to host it in — especially in kiosk mode — so the edit happens
right here, in an overlay inside the HUD window.

Ctrl+S saves (the live-reload picks the file up within a tick and the HUD
re-themes itself; a YAML error lands in the help bar, not a crash).
Esc discards and closes.
"""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QEvent, Qt
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import QLabel, QPlainTextEdit, QVBoxLayout, QWidget

from ..config import SharedConfig
from . import theme

#: bare editor binaries that need a terminal — these get the overlay instead
TERMINAL_EDITORS = {
    "vi", "vim", "nvim", "gvim", "nano", "micro", "emacs", "hx", "helix",
    "pico", "joe", "kak", "kakoune", "mcedit", "ne", "tilde", "ed",
}


class ConfigEditorOverlay(QWidget):
    """A themed text box over the HUD, editing config.yaml in place."""

    def __init__(self, cfg: SharedConfig, window: QWidget) -> None:
        super().__init__(window)
        self.cfg = cfg
        self._window = window
        self.setObjectName("configOverlay")
        self.setStyleSheet(
            f"QWidget#configOverlay {{"
            f"  background: {cfg.colors.get('background', '#0b1220')};"
            f"  border: 1px solid {cfg.colors.get('border', '#38bdf8')};"
            f"}}"
        )

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 10, 14, 10)
        layout.setSpacing(6)

        self._hint = QLabel(f"editing {cfg.path}  —  ctrl+s save · esc discard")
        self._hint.setFont(theme.make_font(cfg, "small"))
        self._hint.setStyleSheet(
            f"color: {cfg.colors.get('help_text', '#64748b')}; border: none;"
        )
        layout.addWidget(self._hint)

        self._editor = QPlainTextEdit()
        self._editor.setFont(theme.make_font(cfg, "label"))
        self._editor.setStyleSheet(
            f"QPlainTextEdit {{"
            f"  background: {cfg.colors.get('box_fill', '#0b1220')};"
            f"  color: {cfg.colors.get('text_normal', '#4ade80')};"
            f"  border: none;"
            f"  selection-background-color: {cfg.colors.get('border', '#38bdf8')};"
            f"}}"
        )
        try:
            self._editor.setPlainText(cfg.path.read_text(encoding="utf-8"))
        except OSError as exc:
            self._editor.setPlainText(f"# could not read {cfg.path}: {exc}\n")
        layout.addWidget(self._editor, stretch=1)

        save_sc = QShortcut(QKeySequence("Ctrl+S"), self)
        save_sc.activated.connect(self._save)
        esc = QShortcut(QKeySequence("Escape"), self)
        esc.activated.connect(self.close)

        window.installEventFilter(self)  # follow window resizes while open
        self._fit()
        self.show()
        self.raise_()
        self._editor.setFocus()

    def _fit(self) -> None:
        rect = self._window.rect().adjusted(40, 40, -40, -40)
        if rect.width() < 100 or rect.height() < 100:  # tiny window: just fill
            rect = self._window.rect()
        self.setGeometry(rect)

    def eventFilter(self, obj, event) -> bool:  # noqa: N802 (Qt naming)
        if obj is self._window and event.type() == QEvent.Resize:
            self._fit()
        return super().eventFilter(obj, event)

    def _save(self) -> None:
        try:
            self.cfg.path.write_text(self._editor.toPlainText(), encoding="utf-8")
        except OSError as exc:
            self._hint.setText(f"save failed: {exc}  —  ctrl+s retry · esc discard")
            self._hint.setStyleSheet(
                f"color: {self.cfg.colors.get('text_crit', '#f87171')}; border: none;"
            )
            return
        toast = getattr(self._window, "toast", None)
        if toast is not None:
            toast.show_message(
                "config saved — reloading", self.cfg.colors.get("text_normal", "#4ade80")
            )
        self.close()

    def close(self) -> bool:  # noqa: A003 (Qt naming)
        self._window.removeEventFilter(self)
        return super().close()
