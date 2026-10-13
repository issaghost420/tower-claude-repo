"""Theme — turns SharedConfig into QSS, QFonts, and colors for the Qt HUD.

One place owns the visual language: dark navy ground, square cyan boxes,
teal labels, green values, violet mins, amber maxes, threshold-driven
recoloring. Widgets ask this module; they never read raw config keys.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtGui import QColor, QFont, QFontDatabase

from ..config import SharedConfig


def resolve_family(cfg: SharedConfig) -> str:
    """First configured family that actually exists on this machine."""
    available = set(QFontDatabase.families())
    for fam in cfg.font_family_candidates:
        if fam in available:
            return fam
    # last resort: the platform's fixed-width default
    return QFontDatabase.systemFont(QFontDatabase.FixedFont).family()


def make_font(cfg: SharedConfig, cls: str) -> QFont:
    spec = cfg.font_class(cls)
    font = QFont(resolve_family(cfg))
    font.setPixelSize(spec["size"])
    font.setBold(spec["bold"])
    font.setItalic(spec["italic"])
    return font


def build_qss(cfg: SharedConfig) -> str:
    """Global stylesheet. Static per config load — rebuilt only on reload."""
    c = cfg.colors
    bg = c.get("background", "#0b1220")
    fill = c.get("box_fill", bg)
    border = c.get("border", "#38bdf8")
    bw = cfg.border_width           # global border thickness, px
    label_c = c.get("text_label", "#2dd4bf")
    underline = bw if cfg.title_underline else 0
    return f"""
    HazyHudWindow, QWidget#root, QWidget#canvas {{
        background: {bg};
    }}
    QWidget#root {{
        background: {bg};
    }}
    QWidget#canvas {{
        background: {bg};
    }}
    QFrame#box {{
        background: {fill};
        border: {bw}px solid {border};
    }}
    QFrame#box[dropTarget="true"] {{
        border: {max(bw, 1)}px dashed {c.get("text_max", "#fbbf24")};
    }}
    QLabel {{
        background: transparent;
        border: none;
    }}
    QLabel#boxTitle {{
        color: {label_c};
        border-bottom: {underline}px solid {border};
        padding-bottom: {3 if underline else 0}px;
    }}
    QLabel#colHeader {{
        color: {label_c};
    }}
    QLabel#rowLabel {{
        color: {label_c};
    }}
    QLabel#dimText {{
        color: {c.get("text_dim", "#818cf8")};
    }}
    QFrame#hairline {{
        background: {border};
        max-height: {bw}px;
        min-height: {bw}px;
        border: none;
    }}
    QListWidget#modes {{
        background: {fill};
        border: none;
        outline: none;
        color: {c.get("text_normal", "#4ade80")};
    }}
    QListWidget#modes::item {{
        padding: 1px 4px;
    }}
    QListWidget#modes::item:selected {{
        background: #16233b;
        color: {c.get("text_normal", "#4ade80")};
    }}
    QListWidget#modes:focus {{
        border: none;
    }}
    QToolTip {{
        background: #16233b;
        color: {c.get("text_normal", "#4ade80")};
        border: {max(bw, 1)}px solid {border};
    }}
    """


def state_color(cfg: SharedConfig, metric: str, value: Optional[float]) -> str:
    return cfg.color_of(metric, value)


def gradient_qcolor(cfg: SharedConfig, fraction: float) -> QColor:
    """Sample the configured bar gradient at a fill fraction (0..1).

    The bar's fill color reflects the *zone* the value sits in — blue at the
    cold end through green/yellow to red — per the configured stops.
    """
    stops = cfg.bar_gradient
    fraction = max(0.0, min(1.0, fraction))
    if fraction <= stops[0][0]:
        return QColor(stops[0][1])
    if fraction >= stops[-1][0]:
        return QColor(stops[-1][1])
    for (a_pos, a_col), (b_pos, b_col) in zip(stops, stops[1:]):
        if a_pos <= fraction <= b_pos:
            span = b_pos - a_pos or 1e-6
            t = (fraction - a_pos) / span
            a, b = QColor(a_col), QColor(b_col)
            return QColor(
                int(a.red() + (b.red() - a.red()) * t),
                int(a.green() + (b.green() - a.green()) * t),
                int(a.blue() + (b.blue() - a.blue()) * t),
            )
    return QColor(stops[-1][1])
