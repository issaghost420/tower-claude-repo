"""SharedConfig — one YAML file, live-reloaded, read by every frontend.

Path resolution (first hit wins):
1. ``HAZYHUD_CONFIG`` env var
2. ``~/.config/hazyhud/config.yaml``
3. built-in defaults (missing file is fine — you get the default layout)

Live reload: mtime polling. ``check_reload()`` is cheap (one stat); frontends
call it on every poll tick, so a saved config lands in ~1 poll interval,
no restart, no watchdog dependency. On change, registered callbacks fire
with the new config so the UI can re-theme/re-layout.

User config is deep-merged over defaults, so a config that only overrides
``colors.border`` still gets every other default.

Config surface (v2.1)
---------------------
- ``poll_interval_ms``   sampling cadence (clamped >= 250)
- ``coolercontrol``      daemon connection + device matching
- ``layout``             grid placement, columns, margins, spacing, padding
- ``window``             normal-mode window: default size, geometry memory
- ``kiosk``              frameless always-on-top mode for dedicated displays
- ``fonts``              family (+fallbacks), global scale (clamped 0.6-2.0),
                         per-class size/bold/italic (title/header/label/value/
                         small/help). Terminal frontends ignore sizes they
                         can't honor; Qt honors everything.
- ``colors``             full palette incl. box fill, bar track, help text
- ``bars``               thin per-box gradient bars: source metric per widget,
                         normalization ranges, gradient stops, height
- ``help_bar``           visible/position (8 orientations), toggle key: h
- ``editor``             editor command for the open-config key (e)
- ``thresholds``         warn/crit per metric, drives colors and bar gradient

Numeric inputs are clamped to sane ranges (see ``_clamp``) so a typo makes
the UI ugly-at-worst, never broken.
"""

from __future__ import annotations

import copy
import os
from pathlib import Path
from typing import Any, Callable, Optional

import yaml


def _clamp(value: Any, lo: float, hi: float, default: float) -> float:
    try:
        return max(lo, min(hi, float(value)))
    except (TypeError, ValueError):
        return default


DEFAULT_GRADIENT = [
    {"at": 0.00, "color": "#38bdf8"},   # blue  — cold / idle
    {"at": 0.40, "color": "#4ade80"},   # green — nominal
    {"at": 0.70, "color": "#facc15"},   # yellow — warm
    {"at": 0.90, "color": "#f87171"},   # red   — hot
]

DEFAULTS: dict[str, Any] = {
    "poll_interval_ms": 1000,
    "coolercontrol": {
        "host": "localhost",
        "port": 11987,
        "token": None,          # cc_... bearer token (preferred auth)
        "password": None,       # daemon admin password (alternative auth)
        "timeout_s": 2.0,
        # Which CC device holds the loop sensors (case-insensitive substring).
        # "octo" matches "Aquacomputer OCTO". Empty string = all devices.
        "aqua_device_match": "octo",
        # Which CC device(s) the fan grid reads. Empty = all fan channels.
        "fan_device_match": "",
    },
    "layout": {
        "preset": "full",
        "mode": "grid",                # grid (spreadsheet) | free (drag canvas)
        "snap_to_grid": False,         # free mode: quantize moves/resizes to a grid
        "grid_size": 8,                # free mode: px cell for snap_to_grid
        "snap_to_edges": True,         # free mode: magnet to window + tile edges
        "allow_overlap": False,        # free mode: let tiles cover each other
        "margin": 10,                  # px between window edge and grid
        "spacing": 10,                 # px between boxes
        "box_padding": {"x": 14, "y": 10},   # px inside each box
        "row_spacing": 2,              # px between metric rows inside a box
        "draggable": True,             # drag boxes by their title bar to swap cells
        "fill": True,                  # False = boxes size to content, slack pools
                                       # bottom-right instead of inflating boxes
        "spread_rows": True,           # False = metric rows pack single-line at the
                                       # top of each box instead of spreading out
        "allow_squash": False,         # True = boxes can shrink BELOW their content
                                       # size (grip/config can clip/overlap text),
                                       # like a normal window. False = content is
                                       # the floor (original behavior).
        "min_box": {"width": 120, "height": 80},  # grip resize floor in px. Drop
                                       # these with allow_squash on to get tiny.
        "snap_resize": False,          # True = when you finish a grip resize, snap
                                       # the box's height to the shortest box in its
                                       # grid row (within ~24px) so rows line up.
        # NOTE: no "columns"/"widgets" here — those come from the active
        # preset (see DEFAULT_PRESETS) unless the user sets them explicitly.
    },
    "window": {
        "width": 0,                 # 0 = auto (content-sized)
        "height": 0,
        "remember_geometry": True,  # restore last position/size on launch
        "title": "hazyhud",
    },
    "launch": {
        # free mode: reopen with tiles where you left them. The layout
        # autosaves to last-layout.yaml (next to config.yaml) on every tile
        # move/resize. false = always seed fresh from the preset's grid.
        "restore_last_layout": True,
        # preset to open with, e.g. "compact". Ignored while
        # restore_last_layout is true.
        "launch_layout": "",
    },
    "kiosk": {
        "enabled": False,           # or run `hazyhud --kiosk`
        "screen": 0,                # monitor index (0 = primary)
        "frameless": True,
        "always_on_top": True,
        "skip_taskbar": True,
    },
    "fonts": {
        "family": "JetBrains Mono",
        # tried in order if `family` isn't installed
        "fallbacks": ["Cascadia Mono", "DejaVu Sans Mono", "Noto Sans Mono"],
        # global multiplier, clamped to 0.6..2.0 — this is the "text sizing"
        # dial. 1.0 = sizes below as written.
        "scale": 1.0,
        # Per-class typography. size is px at scale 1.0 (clamped 6..72).
        "classes": {
            "title":  {"size": 15, "bold": True,  "italic": False},
            "header": {"size": 13, "bold": True,  "italic": False},
            "label":  {"size": 14, "bold": False, "italic": False},
            "value":  {"size": 20, "bold": True,  "italic": False},
            "small":  {"size": 12, "bold": False, "italic": False},
            "help":   {"size": 12, "bold": False, "italic": False},
        },
    },
    "colors": {
        "background": "#0b1220",
        "box_fill": "#0b1220",      # box interior; keep == background for the flat look
        "border": "#38bdf8",
        "text_normal": "#4ade80",
        "text_warn": "#facc15",
        "text_crit": "#f87171",
        "text_dim": "#818cf8",
        "text_label": "#2dd4bf",
        "text_max": "#fbbf24",
        "bar_track": "#16233b",     # empty part of a bar
        "help_text": "#64748b",
        "help_key": "#fbbf24",
    },
    "style": {
        "border_width": 1,          # px thickness for box borders + underlines
        "title_underline": True,    # draw an underline beneath every box title
        "downscale_font": False,    # shrink a tile's fonts to fit when it's
                                    # too small instead of clipping text
    },
    # Rename box titles. Keys are widget names (cpu, gpu0, gpu1, system, aqua,
    # power_avg, fans, mode_switcher). Sensor row names come from CoolerControl,
    # not here — rename those in the CC UI.
    "titles": {},
    # Per-tile overrides. Any style/border key here wins over the global one
    # for that tile. Example:
    #   tiles:
    #     fans: { border_width: 2, title: "Cooling Fans" }
    "tiles": {},
    "bars": {
        "enabled": True,
        "height": 4,                # px, clamped 2..16 — thin and discrete
        "position": "bottom",       # top | bottom (of the box content)
        # One bar per box. Which metric each box's bar follows:
        "sources": {
            "cpu": "cpu_temp",
            "gpu": "gpu_power",     # both GPU boxes; gpu0/gpu1 override below
            "gpu0": "gpu_power",
            "gpu1": "gpu_power",
            "system": "ram_percent",
            "aqua": "water_temp",
            "power_avg": "total_power",
            "fans": "duty_avg",
            "mode_switcher": "none",
        },
        # Normalization ranges: value at `min` = empty bar, at `max` = full.
        "ranges": {
            "cpu_temp": [20, 95],
            "gpu_temp": [20, 90],
            "cpu_load": [0, 100],
            "gpu_load": [0, 100],
            "cpu_power": [0, 200],
            "gpu_power": [0, 575],
            "water_temp": [20, 50],
            "ram_percent": [0, 100],
            "duty_avg": [0, 100],
            "total_power": [0, 1200],
        },
        # Gradient stops, low -> high. The fill color is sampled at the
        # fill fraction, so the bar *itself* tells you the severity zone.
        "gradient": DEFAULT_GRADIENT,
    },
    "help_bar": {
        "visible": True,
        # bottom-left | bottom-center | bottom-right |
        # top-left    | top-center    | top-right    | left | right
        "position": "bottom-center",
    },
    # Command used by the "open config" key (e). null -> $VISUAL -> $EDITOR
    # -> xdg-open. Terminal editors work if you wrap them, e.g.:
    #   editor: "kitty nvim"
    "editor": None,
    "thresholds": {
        "cpu_temp": {"warn": 70, "crit": 85},
        "gpu_temp": {"warn": 75, "crit": 83},
        "cpu_power": {"warn": 105, "crit": 142},
        "gpu_power": {"warn": 450, "crit": 550},
        "water_temp": {"warn": 42, "crit": 48},
        "ram_percent": {"warn": 75, "crit": 90},
    },
}

# Presets are named layout bundles: {columns, widgets}. The active one is
# chosen by layout.preset (or the `p` key, which cycles live). Users can add
# their own under `presets:` in config.yaml — same shape. Anything under
# layout.widgets overrides the preset's placement for that widget; setting a
# widget to null hides it.
DEFAULT_PRESETS: dict[str, Any] = {
    # The classic 3-column HUD. Built-in default.
    "full": {
        "columns": 3,
        "widgets": {
            "cpu":           {"row": 0, "col": 0},
            "gpu0":          {"row": 0, "col": 1},
            "gpu1":          {"row": 0, "col": 2},
            "system":        {"row": 1, "col": 0},
            "aqua":          {"row": 1, "col": 1},
            "power_avg":     {"row": 1, "col": 2},
            "fans":          {"row": 2, "col": 0, "colspan": 2},
            "mode_switcher": {"row": 2, "col": 2},
        },
    },
    # Two columns, stacked — narrow windows, portrait-ish panels.
    "compact": {
        "columns": 2,
        "widgets": {
            "cpu":           {"row": 0, "col": 0},
            "gpu0":          {"row": 0, "col": 1},
            "gpu1":          {"row": 1, "col": 0},
            "system":        {"row": 1, "col": 1},
            "aqua":          {"row": 2, "col": 0},
            "power_avg":     {"row": 2, "col": 1},
            "fans":          {"row": 3, "col": 0, "colspan": 2},
            "mode_switcher": {"row": 4, "col": 0, "colspan": 2},
        },
    },
    # The loop, front and center: coolant, power, fans, modes. 2x2.
    "cooling": {
        "columns": 2,
        "widgets": {
            "aqua":          {"row": 0, "col": 0},
            "power_avg":     {"row": 0, "col": 1},
            "fans":          {"row": 1, "col": 0},
            "mode_switcher": {"row": 1, "col": 1},
        },
    },
    # Just the silicon: CPU + GPUs on top, system + power below.
    "minimal": {
        "columns": 3,
        "widgets": {
            "cpu":       {"row": 0, "col": 0},
            "gpu0":      {"row": 0, "col": 1},
            "gpu1":      {"row": 0, "col": 2},
            "system":    {"row": 1, "col": 0},
            "power_avg": {"row": 1, "col": 2},
        },
    },
}

# Friendly names that resolve to real widgets, so config from older docs
# (the v2 prompt used `ram:`) doesn't silently vanish.
WIDGET_ALIASES = {
    "ram": "system",
    "modes": "mode_switcher",
    "coolant": "aqua",
    "water": "aqua",
    "power": "power_avg",
}

HELP_BAR_POSITIONS = {
    "bottom-left", "bottom-center", "bottom-right",
    "top-left", "top-center", "top-right",
    "left", "right",
}

FONT_CLASSES = ("title", "header", "label", "value", "small", "help")


def default_config_path() -> Path:
    env = os.environ.get("HAZYHUD_CONFIG")
    if env:
        return Path(env).expanduser()
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg).expanduser() if xdg else Path.home() / ".config"
    return base / "hazyhud" / "config.yaml"


def _deep_merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = value
    return out


class SharedConfig:
    """Live-reloading view over the YAML config file."""

    def __init__(self, path: Optional[Path] = None) -> None:
        self.path = Path(path) if path else default_config_path()
        self._data: dict[str, Any] = copy.deepcopy(DEFAULTS)
        self._user: dict[str, Any] = {}   # raw user YAML, pre-merge
        self._mtime_ns: Optional[int] = None
        self._callbacks: list[Callable[["SharedConfig"], None]] = []
        self.last_error: Optional[str] = None
        self.layout_warnings: list[str] = []
        self.reload()

    # -- loading ------------------------------------------------------------

    def reload(self) -> bool:
        """Reload from disk. Returns True if the file content was applied."""
        try:
            raw = self.path.read_text(encoding="utf-8")
            parsed = yaml.safe_load(raw) or {}
            if not isinstance(parsed, dict):
                raise ValueError("top-level YAML node must be a mapping")
            self._user = parsed
            self._data = _deep_merge(DEFAULTS, parsed)
            self._mtime_ns = self.path.stat().st_mtime_ns
            self.last_error = None
            return True
        except FileNotFoundError:
            self._user = {}
            self._data = copy.deepcopy(DEFAULTS)
            self._mtime_ns = None
            self.last_error = None
            return False
        except (OSError, ValueError, yaml.YAMLError) as exc:
            # Keep the last good config; a half-saved file shouldn't blank the HUD.
            self.last_error = f"config not applied: {exc}"
            try:
                self._mtime_ns = self.path.stat().st_mtime_ns
            except OSError:
                pass
            return False

    def check_reload(self) -> bool:
        """Stat the file; reload + fire callbacks if it changed. Cheap per tick."""
        try:
            mtime = self.path.stat().st_mtime_ns
        except OSError:
            mtime = None
        if mtime == self._mtime_ns:
            return False
        applied = self.reload()
        if applied:
            for cb in self._callbacks:
                cb(self)
        return applied

    def on_reload(self, callback: Callable[["SharedConfig"], None]) -> None:
        self._callbacks.append(callback)

    # -- generic access -------------------------------------------------------

    def get(self, *keys: str, default: Any = None) -> Any:
        node: Any = self._data
        for key in keys:
            if not isinstance(node, dict) or key not in node:
                return default
            node = node[key]
        return node

    @property
    def poll_interval_ms(self) -> int:
        return int(_clamp(self.get("poll_interval_ms", default=1000), 250, 60000, 1000))

    # -- colors & thresholds ----------------------------------------------------

    @property
    def colors(self) -> dict[str, str]:
        merged = dict(DEFAULTS["colors"])
        merged.update(self.get("colors", default={}) or {})
        return merged

    # -- style / borders / titles ----------------------------------------------

    def _tile_cfg(self, widget: str) -> dict:
        return (self.get("tiles", default={}) or {}).get(widget, {}) or {}

    @property
    def border_width(self) -> int:
        return int(_clamp(self.get("style", "border_width", default=1), 0, 12, 1))

    def border_width_for(self, widget: str) -> int:
        """Per-tile border thickness, falling back to the global value."""
        v = self._tile_cfg(widget).get("border_width")
        if v is None:
            return self.border_width
        return int(_clamp(v, 0, 12, self.border_width))

    @property
    def title_underline(self) -> bool:
        return bool(self.get("style", "title_underline", default=True))

    def title_underline_for(self, widget: str) -> bool:
        v = self._tile_cfg(widget).get("title_underline")
        return self.title_underline if v is None else bool(v)

    @property
    def downscale_font(self) -> bool:
        return bool(self.get("style", "downscale_font", default=False))

    def downscale_font_for(self, widget: str) -> bool:
        v = self._tile_cfg(widget).get("downscale_font")
        return self.downscale_font if v is None else bool(v)

    def title_for(self, widget: str, default: str) -> str:
        """Renamed title for a widget: per-tile `title` wins, then the
        `titles` map, then the built-in default."""
        t = self._tile_cfg(widget).get("title")
        if t:
            return str(t)
        t = (self.get("titles", default={}) or {}).get(widget)
        return str(t) if t else default

    def set_title(self, widget: str, title: str) -> None:
        """Persist a renamed title into the `titles` map (for double-click
        rename in the app)."""
        titles = dict(self.get("titles", default={}) or {})
        titles[widget] = title
        self._data.setdefault("titles", {})
        self._data["titles"] = titles

    @property
    def thresholds(self) -> dict[str, dict[str, float]]:
        return dict(self.get("thresholds", default=DEFAULTS["thresholds"]))

    def state_of(self, metric: str, value: Optional[float]) -> str:
        """Map a value to 'normal' | 'warn' | 'crit' using configured thresholds."""
        if value is None:
            return "normal"
        th = self.thresholds.get(metric) or {}
        warn, crit = th.get("warn"), th.get("crit")
        try:
            if crit is not None and value >= float(crit):
                return "crit"
            if warn is not None and value >= float(warn):
                return "warn"
        except (TypeError, ValueError):
            pass
        return "normal"

    def color_of(self, metric: str, value: Optional[float]) -> str:
        colors = self.colors
        return {
            "normal": colors.get("text_normal", "#4ade80"),
            "warn": colors.get("text_warn", "#facc15"),
            "crit": colors.get("text_crit", "#f87171"),
        }[self.state_of(metric, value)]

    # -- layout ---------------------------------------------------------------

    # -- presets & widget placement -----------------------------------------

    def user_has(self, *keys: str) -> bool:
        """True if the *user's own YAML* (not the merged defaults) sets a key."""
        node: Any = self._user
        for key in keys:
            if not isinstance(node, dict) or key not in node:
                return False
            node = node[key]
        return True

    def presets(self) -> dict[str, Any]:
        """Built-in presets deep-merged with the user's own `presets:` section."""
        return _deep_merge(DEFAULT_PRESETS, self.get("presets", default={}) or {})

    def preset_names(self) -> list[str]:
        return list(self.presets().keys())

    def _active_preset(self, override: Optional[str] = None) -> dict[str, Any]:
        name = override or str(self.get("layout", "preset", default="full"))
        all_presets = self.presets()
        if name not in all_presets:
            return all_presets.get("full", {})
        return all_presets[name]

    def widget_placements(self, preset_override: Optional[str] = None) -> dict[str, dict[str, int]]:
        """Resolve the final grid: active preset, overridden by layout.widgets.

        A widget set to null/false in layout.widgets is hidden. Per-widget
        keys: row, col, colspan, rowspan, min_width, min_height,
        max_width, max_height (px, 0 = no limit), hstretch, vstretch
        (relative resize weight vs. other columns/rows).
        """
        preset_widgets = self._active_preset(preset_override).get("widgets", {})
        user_widgets = self.get("layout", "widgets", default={}) or {}

        # Collision rule: user-defined widgets place first and always win.
        # A preset widget whose cells are taken is hidden (with a warning),
        # never stacked on top of another box. Same-name preset entries are
        # skipped — the user's version already covers them.
        hidden = {
            WIDGET_ALIASES.get(str(n), str(n))
            for n, spec in user_widgets.items()
            if spec is None or spec is False
        }
        self.layout_warnings: list[str] = []
        occupied: dict[tuple[int, int], str] = {}
        out: dict[str, dict[str, int]] = {}

        def _cells(spec: dict) -> list[tuple[int, int]]:
            row = int(_clamp(spec.get("row", 0), 0, 32, 0))
            col = int(_clamp(spec.get("col", 0), 0, 8, 0))
            rows = int(_clamp(spec.get("rowspan", 1), 1, 8, 1))
            cols = int(_clamp(spec.get("colspan", 1), 1, 8, 1))
            return [(r, c) for r in range(row, row + rows) for c in range(col, col + cols)]

        for widgets in (user_widgets, preset_widgets):  # user first — wins ties
            for name, spec in sorted(
                ((n, s) for n, s in widgets.items() if isinstance(s, dict)),
                key=lambda kv: (kv[1].get("row", 0), kv[1].get("col", 0)),
            ):
                name = WIDGET_ALIASES.get(str(name), str(name))
                if name in hidden or name in out:
                    continue
                cells = _cells(spec)
                clash = next((cell for cell in cells if cell in occupied), None)
                if clash is not None:
                    self.layout_warnings.append(
                        f"{name} overlaps {occupied[clash]} at r{clash[0]}c{clash[1]} — hidden"
                    )
                    continue
                for cell in cells:
                    occupied[cell] = name
                out[name] = {
                    "row": int(_clamp(spec.get("row", 0), 0, 32, 0)),
                    "col": int(_clamp(spec.get("col", 0), 0, 8, 0)),
                    "colspan": int(_clamp(spec.get("colspan", 1), 1, 8, 1)),
                    "rowspan": int(_clamp(spec.get("rowspan", 1), 1, 8, 1)),
                    "min_width": int(_clamp(spec.get("min_width", 0), 0, 4000, 0)),
                    "min_height": int(_clamp(spec.get("min_height", 0), 0, 4000, 0)),
                    "max_width": int(_clamp(spec.get("max_width", 0), 0, 4000, 0)),
                    "max_height": int(_clamp(spec.get("max_height", 0), 0, 4000, 0)),
                    "hstretch": int(_clamp(spec.get("hstretch", 0), 0, 10, 0)),
                    "vstretch": int(_clamp(spec.get("vstretch", 0), 0, 10, 0)),
                }
        return out

    def layout_columns_for(self, preset_override: Optional[str] = None) -> int:
        """Explicit layout.columns wins; otherwise the active preset's."""
        if self.user_has("layout", "columns"):
            return int(_clamp(self.get("layout", "columns", default=3), 1, 8, 3))
        cols = self._active_preset(preset_override).get("columns", 3)
        return int(_clamp(cols, 1, 8, 3))

    @property
    def layout_columns(self) -> int:
        return self.layout_columns_for()

    @property
    def layout_margin(self) -> int:
        return int(_clamp(self.get("layout", "margin", default=10), 0, 60, 10))

    @property
    def layout_spacing(self) -> int:
        return int(_clamp(self.get("layout", "spacing", default=10), 0, 40, 10))

    @property
    def box_padding(self) -> tuple[int, int]:
        pad = self.get("layout", "box_padding", default={}) or {}
        x = int(_clamp(pad.get("x", 14), 0, 40, 14))
        y = int(_clamp(pad.get("y", 10), 0, 40, 10))
        return x, y

    @property
    def row_spacing(self) -> int:
        return int(_clamp(self.get("layout", "row_spacing", default=2), 0, 20, 2))

    @property
    def layout_draggable(self) -> bool:
        return bool(self.get("layout", "draggable", default=True))

    @property
    def layout_fill(self) -> bool:
        return bool(self.get("layout", "fill", default=True))

    @property
    def layout_spread_rows(self) -> bool:
        return bool(self.get("layout", "spread_rows", default=True))

    @property
    def layout_allow_squash(self) -> bool:
        return bool(self.get("layout", "allow_squash", default=False))

    @property
    def min_box_size(self) -> tuple[int, int]:
        """Grip resize floor + squash-mode minimumSizeHint, in px."""
        mb = self.get("layout", "min_box", default={}) or {}
        w = int(_clamp(mb.get("width", 120), 0, 4000, 120))
        h = int(_clamp(mb.get("height", 80), 0, 4000, 80))
        return w, h

    @property
    def layout_snap_resize(self) -> bool:
        return bool(self.get("layout", "snap_resize", default=False))

    # -- free canvas mode -------------------------------------------------------

    @property
    def layout_mode(self) -> str:
        mode = str(self.get("layout", "mode", default="grid")).lower()
        return mode if mode in ("grid", "free") else "grid"

    @property
    def free_snap_to_grid(self) -> bool:
        return bool(self.get("layout", "snap_to_grid", default=False))

    @property
    def free_grid_size(self) -> int:
        return int(_clamp(self.get("layout", "grid_size", default=8), 1, 200, 8))

    @property
    def free_snap_to_edges(self) -> bool:
        return bool(self.get("layout", "snap_to_edges", default=True))

    @property
    def free_allow_overlap(self) -> bool:
        return bool(self.get("layout", "allow_overlap", default=False))

    # -- fonts ------------------------------------------------------------------

    @property
    def font_scale(self) -> float:
        return _clamp(self.get("fonts", "scale", default=1.0), 0.6, 2.0, 1.0)

    @property
    def font_family_candidates(self) -> list[str]:
        fam = self.get("fonts", "family", default="JetBrains Mono")
        fallbacks = self.get("fonts", "fallbacks", default=[]) or []
        out = [str(fam)] if fam else []
        out.extend(str(f) for f in fallbacks)
        out.append("monospace")
        return out

    def font_class(self, name: str) -> dict[str, Any]:
        """{'size': px (scaled, clamped), 'bold': bool, 'italic': bool}"""
        classes = self.get("fonts", "classes", default={}) or {}
        spec = classes.get(name) or DEFAULTS["fonts"]["classes"][name]
        size = _clamp(spec.get("size", 12), 6, 72, 12) * self.font_scale
        return {
            "size": int(round(_clamp(size, 6, 96, 12))),
            "bold": bool(spec.get("bold", False)),
            "italic": bool(spec.get("italic", False)),
        }

    # -- bars --------------------------------------------------------------------

    @property
    def bars_enabled(self) -> bool:
        return bool(self.get("bars", "enabled", default=True))

    @property
    def bar_height(self) -> int:
        return int(_clamp(self.get("bars", "height", default=4), 2, 16, 4))

    @property
    def bar_position(self) -> str:
        pos = str(self.get("bars", "position", default="bottom")).lower()
        return pos if pos in ("top", "bottom") else "bottom"

    def bar_source(self, widget_name: str) -> Optional[str]:
        """Metric key a box's bar follows, or None if the box has no bar."""
        sources = self.get("bars", "sources", default={}) or {}
        src = sources.get(widget_name)
        if src is None and widget_name.startswith("gpu"):
            src = sources.get("gpu")
        if src is None or str(src).lower() in ("none", "off", ""):
            return None
        return str(src)

    def bar_range(self, metric: str) -> tuple[float, float]:
        ranges = self.get("bars", "ranges", default={}) or {}
        lo_hi = ranges.get(metric) or [0, 100]
        try:
            lo, hi = float(lo_hi[0]), float(lo_hi[1])
        except (TypeError, ValueError, IndexError):
            lo, hi = 0.0, 100.0
        if hi <= lo:
            hi = lo + 1.0
        return lo, hi

    def bar_fraction(self, metric: str, value: Optional[float]) -> Optional[float]:
        if value is None:
            return None
        lo, hi = self.bar_range(metric)
        return max(0.0, min(1.0, (float(value) - lo) / (hi - lo)))

    @property
    def bar_gradient(self) -> list[tuple[float, str]]:
        raw = self.get("bars", "gradient", default=DEFAULT_GRADIENT) or DEFAULT_GRADIENT
        stops: list[tuple[float, str]] = []
        for stop in raw:
            try:
                at = _clamp(stop.get("at", 0), 0.0, 1.0, 0.0)
                color = str(stop.get("color", "#4ade80"))
                stops.append((at, color))
            except (AttributeError, TypeError):
                continue
        stops.sort(key=lambda s: s[0])
        return stops or [(0.0, "#38bdf8"), (1.0, "#f87171")]

    # -- help bar ------------------------------------------------------------------

    @property
    def help_bar_visible(self) -> bool:
        return bool(self.get("help_bar", "visible", default=True))

    @property
    def help_bar_position(self) -> str:
        pos = str(self.get("help_bar", "position", default="bottom-center")).lower()
        return pos if pos in HELP_BAR_POSITIONS else "bottom-center"

    # -- window / kiosk --------------------------------------------------------------

    @property
    def launch_restore_last_layout(self) -> bool:
        return bool(self.get("launch", "restore_last_layout", default=True))

    @property
    def kiosk(self) -> dict[str, Any]:
        k = self.get("kiosk", default={}) or {}
        return {
            "enabled": bool(k.get("enabled", False)),
            "screen": int(_clamp(k.get("screen", 0), 0, 16, 0)),
            "frameless": bool(k.get("frameless", True)),
            "always_on_top": bool(k.get("always_on_top", True)),
            "skip_taskbar": bool(k.get("skip_taskbar", True)),
        }

    @property
    def window_title(self) -> str:
        return str(self.get("window", "title", default="hazyhud"))

    # -- coolercontrol -------------------------------------------------------------

    @property
    def cc_host(self) -> str:
        return str(self.get("coolercontrol", "host", default="localhost"))

    @property
    def cc_port(self) -> int:
        return int(self.get("coolercontrol", "port", default=11987))

    @property
    def cc_token(self) -> Optional[str]:
        token = self.get("coolercontrol", "token")
        return str(token) if token else None

    @property
    def cc_password(self) -> Optional[str]:
        password = self.get("coolercontrol", "password")
        return str(password) if password else None

    @property
    def cc_timeout(self) -> float:
        return float(self.get("coolercontrol", "timeout_s", default=2.0))

    # -- editor -------------------------------------------------------------------

    def editor_command(self) -> list[str]:
        """Resolve the editor for the open-config key, as an argv list."""
        import shlex

        configured = self.get("editor")
        candidates = [configured, os.environ.get("VISUAL"), os.environ.get("EDITOR")]
        for cand in candidates:
            if cand:
                return shlex.split(str(cand))
        return ["xdg-open"]


def write_default_config(path: Optional[Path] = None) -> Path:
    """Write the starter config and a read-only defaults reference.

    - ``config.yaml`` is only written if it doesn't already exist (never
      overwrites user edits).
    - ``config-defaults.yaml`` is always written fresh — it's a pristine
      reference copy the user can diff against. If running as root it gets
      root:root ownership; otherwise it's set read-only (0o444).
    """
    path = Path(path) if path else default_config_path()
    path.parent.mkdir(parents=True, exist_ok=True)

    # User's config — only if it doesn't exist yet
    wrote_config = False
    if not path.exists():
        path.write_text(STARTER_CONFIG, encoding="utf-8")
        wrote_config = True

    # Read-only defaults reference — always overwritten
    defaults_path = path.parent / "config-defaults.yaml"
    defaults_path.write_text(STARTER_CONFIG, encoding="utf-8")
    if os.getuid() == 0:
        import shutil
        shutil.chown(defaults_path, user="root", group="root")
        defaults_path.chmod(0o644)
    else:
        defaults_path.chmod(0o444)

    return path if wrote_config else defaults_path


STARTER_CONFIG = """\
# ═══════════════════════════════════════════════════════════════════════════
# HazyHud config — both the Qt HUD and the TUI read from this same file.
#
# Save it, and the running app picks up your changes on the next tick (~1s).
# No restart needed, ever. Just save and watch it update.
#
# If you leave something out, the built-in default kicks in. Delete whole
# sections if you want — nothing breaks. Numbers get clamped to sane ranges
# so a fat-finger makes things ugly at worst, never crashes anything.
# ═══════════════════════════════════════════════════════════════════════════

poll_interval_ms: 1000        # sensor sampling rate in ms (250 minimum)

# ── CoolerControl ───────────────────────────────────────────────────────────
# Fan speeds, coolant temps, flow rates, and cooling mode switching all come
# from the CoolerControl daemon over its REST API.
coolercontrol:
  host: localhost
  port: 11987
  # Newer CC versions turn on Access Protection by default. Two ways to auth:
  #   token    — best option. Go to CC UI -> Access Protection -> create one.
  #              Read-only is enough to monitor; mode switching needs WRITE.
  #   password — the daemon admin password. Works but token is cleaner.
  # If you set either of these, chmod 600 this file so nobody else reads it.
  token: null
  password: null
  timeout_s: 2.0
  aqua_device_match: octo   # substring match (case-insensitive) for the CC
                            # device with your loop temps. "" = show all
  fan_device_match: ""      # same idea for the fan box. "" = all fan channels

# ── Layout ──────────────────────────────────────────────────────────────────
# Everything is a grid of boxes — works like a spreadsheet.
#   row/col      = grid coordinates (0-indexed, top-left origin)
#   colspan/rowspan = stretch a box across multiple cells
#
# Available boxes:
#   cpu  gpu0  gpu1  system  aqua  fans  power_avg  mode_switcher
# Shortcuts:  ram->system  coolant->aqua  power->power_avg  modes->mode_switcher
#
# Presets are named layout bundles. I included four:
#   full     — 3 columns, everything visible (default)
#   compact  — 2 columns, stacked for narrower windows
#   cooling  — just the loop: coolant, power, fans, mode switcher
#   minimal  — CPU + GPUs on top, system + power below
# Hit  p  in the app to cycle through them live.
#
# Per-box sizing:
#   min_width / min_height — pixel floor (0 = fit to content)
#   max_width / max_height — hard ceiling, box won't grow past this
#   hstretch / vstretch    — how greedy a box is with leftover space
#                            (2 = takes twice the slack of 1)
#
# Squatty / tile mode (like Home Assistant dashboards):
#   fill: false         — boxes stay content-sized, empty space collects
#                         at the bottom-right instead of stretching things
#   spread_rows: false  — metric rows pack tight at the top of each box
#   box_padding: { x: 10, y: 6 }  and  row_spacing: 0  tighten it up more
layout:
  preset: full
  mode: grid              # grid | free
                          # grid = the spreadsheet layout below (rows/cols).
                          # free = a drag canvas: tiles go anywhere in the
                          # window. Drag the TOP STRIP of a tile (title-bar
                          # height) to move it; drag the fat BOTTOM-RIGHT
                          # CORNER to resize (both directions at once). Tiles
                          # can shrink as small as you like — squash is always
                          # on in free mode. Positions save per-tile
                          # automatically; presets/widgets/columns are ignored.
                          # Press 'o' (oops) to reset tiles if they get messy.
  # ── free-mode snapping (only used when mode: free) ──
  snap_to_edges: true     # tiles magnet to the window edges and to each
                          # other's edges so they click together cleanly. A
                          # wide tile clears the tallest neighbor it spans, so
                          # staggered layouts just work. Weak/forgiving — it
                          # never fights you.
  snap_to_grid: false     # also quantize moves/resizes to a pixel grid
  grid_size: 8            # px cell for snap_to_grid
  allow_overlap: false    # false = a tile that would cover another slides to
                          # the nearest free spot on drop (no reflow, no
                          # whack-a-mole). true = tiles can overlap freely.
  margin: 10              # px, window edge to grid           (0–60)
  spacing: 10             # px, gap between boxes             (0–40)
  box_padding: { x: 14, y: 10 }   # px, inside each box     (0–40)
  row_spacing: 2          # px, between metric rows in a box  (0–20)
  fill: true              # false = content-sized tiles
  spread_rows: true       # false = rows pack to the top
  allow_squash: false     # true = boxes can shrink BELOW their content size.
                          # This is the "let me get squatty" switch — with it
                          # on, the grip and config can clip/overlap a box's own
                          # labels, like resizing any normal window. With it off
                          # (default), a box never goes smaller than its content.
  min_box: { width: 120, height: 80 }   # grip resize floor in px. Turn these
                          # down (with allow_squash: true) to crush boxes tiny —
                          # the grip itself won't go below ~24px so you can still
                          # grab it, but config min_width/min_height can go lower.
  snap_resize: false      # true = when you let go of a grip resize, snap the
                          # box's height to the shortest box in its grid row if
                          # it's within ~24px. Size one box, then drag the others
                          # in the row close and they'll line up to it.
  draggable: true         # grab a box's title bar and drop it on another to
                          # swap them. Grab the bottom-right corner to resize.
                          # Both persist across restarts (stored separately,
                          # so your comments in this file are safe). To lock
                          # in an arrangement, put it in widgets: below —
                          # explicit values here take back control from drags.

  # Override individual boxes from the preset. You only need to list the
  # ones you're changing. Set a box to null to hide it.
  # widgets:
  #   fans:  { row: 0, col: 0, colspan: 2 }
  #   cpu:   { min_width: 520 }
  #   gpu1:  null
  # columns: 4            # force column count (otherwise uses the preset's)

# ── Custom presets ──────────────────────────────────────────────────────────
# Same shape as the built-ins. Set layout.preset to your name to use it.
# presets:
#   mypreset:
#     columns: 2
#     widgets:
#       gpu0:          { row: 0, col: 0 }
#       gpu1:          { row: 0, col: 1 }
#       fans:          { row: 1, col: 0, colspan: 2 }
#       mode_switcher: { row: 2, col: 0, colspan: 2 }

# ── Window ──────────────────────────────────────────────────────────────────
window:
  width: 0                # 0 = auto-size to content (Qt frontend only)
  height: 0
  remember_geometry: true # remembers position + size between sessions
  title: hazyhud

# ── Launch behavior ─────────────────────────────────────────────────────────
launch:
  restore_last_layout: true  # free mode: reopen with the tiles where you left
                             # them. Positions autosave to last-layout.yaml
                             # (next to this file) on every move/resize —
                             # delete that file or press 'o' to start fresh.
                             # false = always seed fresh from the preset grid.
  launch_layout: ""          # preset to open with, e.g. "compact".
                             # ignored while restore_last_layout is true.

# ── Kiosk mode ──────────────────────────────────────────────────────────────
# For a dedicated display — frameless, always on top, no taskbar entry.
# hazyhud --kiosk forces this on regardless of `enabled`.
#
# WAYLAND NOTE: on Wayland (KDE Plasma's default), apps are NOT allowed to
# position their own windows — the compositor owns placement. So `screen:`
# and any hardcoded position are ignored; only the window SIZE is applied.
# To pin HazyHud to a specific screen/spot on KDE Wayland, use a Window Rule:
#   System Settings → Window Management → Window Rules → New
#   Match: Window class = "hazyhud"
#   Set: "Screen" (force), and/or "Position"/"Size", or "Fullscreen"
# On X11 the `screen:` index below works directly.
kiosk:
  enabled: false
  screen: 0               # monitor index (0 = primary) — X11 only, see above
  frameless: true
  always_on_top: true
  skip_taskbar: true

# ── Fonts ───────────────────────────────────────────────────────────────────
# The Qt HUD respects all of this. The TUI ignores font settings — your
# terminal emulator handles that.
fonts:
  family: JetBrains Mono
  fallbacks: [Cascadia Mono, DejaVu Sans Mono, Noto Sans Mono]
  scale: 1.0              # master text size dial (0.6–2.0)
  classes:                # individual sizes in px at scale 1.0 (clamped 6–72)
    title:  { size: 15, bold: true,  italic: false }
    header: { size: 13, bold: true,  italic: false }
    label:  { size: 14, bold: false, italic: false }
    value:  { size: 20, bold: true,  italic: false }
    small:  { size: 12, bold: false, italic: false }
    help:   { size: 12, bold: false, italic: false }

# ── Colors ──────────────────────────────────────────────────────────────────
colors:
  background: "#0b1220"
  box_fill: "#0b1220"     # same as background = flat look, change for raised
  border: "#38bdf8"
  text_normal: "#4ade80"  # healthy values
  text_warn: "#facc15"    # past warn threshold
  text_crit: "#f87171"    # past crit threshold
  text_dim: "#818cf8"     # mins, secondary info
  text_label: "#2dd4bf"   # titles, labels, headers
  text_max: "#fbbf24"     # maxes
  bar_track: "#16233b"    # empty portion of the bars
  help_text: "#64748b"
  help_key: "#fbbf24"

# ── Style ───────────────────────────────────────────────────────────────────
style:
  border_width: 1         # px thickness of box borders AND title underlines
  title_underline: true   # draw a line under every box title
  downscale_font: false   # when a tile is too small for its text, shrink the
                          # fonts to fit instead of clipping. Off = text keeps
                          # its size and just clips (free mode lets you do that)

# ── Rename titles ───────────────────────────────────────────────────────────
# Keys are widget names: cpu gpu0 gpu1 system aqua power_avg fans mode_switcher
# (You can also double-click a title in the app to rename it live.)
# Sensor ROW names (Sensor 2, Fan 1, etc.) come from CoolerControl — rename
# those in the CC UI, not here.
# titles:
#   fans: "Cooling Fans"
#   power_avg: "Wattage"

# ── Per-tile overrides ──────────────────────────────────────────────────────
# Any style key, plus `title`, set per tile. Overrides the globals above.
# tiles:
#   fans:      { border_width: 2, title: "Cooling Fans" }
#   power_avg: { title_underline: false }

# ── Bars ────────────────────────────────────────────────────────────────────
# Each box gets a thin gradient bar — a quick visual indicator, not a chart.
# The bar length shows the value; the bar COLOR shows what zone it's in
# (blue = cold/idle, green = nominal, yellow = warm, red = hot).
bars:
  enabled: true
  height: 4               # px (2–16)
  position: bottom        # top | bottom
  sources:                # which metric drives each box's bar
    cpu: cpu_temp         #   pick any key from `ranges` below
    gpu: gpu_power        #   default for all gpuN boxes
    gpu0: gpu_power       #   per-GPU override
    gpu1: gpu_power
    system: ram_percent
    aqua: water_temp
    power_avg: total_power
    fans: duty_avg        # average duty across all visible fan channels
    mode_switcher: none   # "none" disables the bar for that box
  ranges:                 # [min, max] = what maps to [empty bar, full bar]
    cpu_temp: [20, 95]
    gpu_temp: [20, 90]
    cpu_load: [0, 100]
    gpu_load: [0, 100]
    cpu_power: [0, 200]
    gpu_power: [0, 575]
    water_temp: [20, 50]
    ram_percent: [0, 100]
    duty_avg: [0, 100]
    total_power: [0, 1200]
  gradient:               # color stops, low to high — add or remove freely
    - { at: 0.0, color: "#38bdf8" }   # blue
    - { at: 0.4, color: "#4ade80" }   # green
    - { at: 0.7, color: "#facc15" }   # yellow
    - { at: 0.9, color: "#f87171" }   # red

# ── Help bar ────────────────────────────────────────────────────────────────
help_bar:
  visible: true           # h key toggles it
  position: bottom-center
  # options: bottom-left | bottom-center | bottom-right
  #          top-left    | top-center    | top-right
  #          left | right  (vertical strip on the window edge)

# ── Editor ──────────────────────────────────────────────────────────────────
# Press e to open this file. Falls back to $VISUAL, then $EDITOR, then xdg-open.
# Terminal editors (micro, nano, vim, ...) open in an editor overlay INSIDE the
# hazyhud window instead — ctrl+s saves (live-reloads), esc discards. Prefer
# your real terminal? Wrap the editor: editor: "kitty nvim"
editor: null

# ── Thresholds ──────────────────────────────────────────────────────────────
# When a value crosses warn or crit, its text color changes and the bar
# gradient reflects it. Tune these to match your hardware.
thresholds:
  cpu_temp:    { warn: 70, crit: 85 }
  gpu_temp:    { warn: 75, crit: 83 }
  cpu_power:   { warn: 105, crit: 142 }
  gpu_power:   { warn: 450, crit: 550 }
  water_temp:  { warn: 42, crit: 48 }
  ram_percent: { warn: 75, crit: 90 }
"""
