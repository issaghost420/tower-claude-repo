"""HazyHud TUI — Textual frontend over the shared data layer.

One process, three loops:
- poll timer (config: poll_interval_ms) → worker thread samples the
  HazyHudCollector and the CoolerControl daemon → widgets re-render
- config mtime check on every tick → save config.yaml, HUD re-themes/re-layouts
  live, no restart
- Textual's own event loop for keys/mouse

Keys:  q quit · r reset min/max & averages · m focus mode switcher
"""

from __future__ import annotations

import re
from typing import Optional

from textual import work
from textual.app import App, ComposeResult
from textual.containers import Grid
from textual.widgets import Footer, Static

from ..cc_client import CCUnavailable, CoolerControlClient
from ..collector import HazyHudCollector
from ..config import SharedConfig
from ..models import CoolingSnapshot
from .widgets import (
    AquaWidget,
    CpuWidget,
    FansWidget,
    GpuWidget,
    MetricTable,
    ModeSwitcherWidget,
    PowerAvgWidget,
    SystemWidget,
)

from .. import __version__


class HazyHudApp(App):
    """System vitals HUD. Dark navy, cyan boxes, threshold-driven color."""

    TITLE = "hazyhud"
    SUB_TITLE = f"v{__version__}"

    ENABLE_COMMAND_PALETTE = False

    DEFAULT_CSS = """
    Screen {
        background: #0b1220;
    }
    #grid {
        padding: 0 1;
        grid-rows: auto;
    }
    #grid > Static {
        height: auto;
        padding: 0 1;
    }
    ModeSwitcherWidget {
        height: auto;
        border: solid #38bdf8;
        padding: 0 1;
    }
    ModeSwitcherWidget OptionList {
        height: auto;
        background: transparent;
        border: none;
    }
    /* 'm' focuses the mode list — make that visible, and make the
       highlighted option readable, or the switcher feels dead. */
    ModeSwitcherWidget:focus-within {
        border: solid #4ade80;
    }
    ModeSwitcherWidget OptionList > .option-list--option-highlighted {
        background: #16233b;
        color: #4ade80;
    }
    Footer {
        background: transparent;
    }
    """

    BINDINGS = [
        ("q", "quit", "quit"),
        ("r", "reset_minmax", "reset min/max"),
        ("m", "focus_modes", "modes"),
    ]

    def __init__(self, config: Optional[SharedConfig] = None) -> None:
        super().__init__()
        self.cfg = config or SharedConfig()
        self.collector = HazyHudCollector()
        self.cc = CoolerControlClient(
            host=self.cfg.cc_host,
            port=self.cfg.cc_port,
            token=self.cfg.cc_token,
            password=self.cfg.cc_password,
            timeout=self.cfg.cc_timeout,
        )
        self._grid = Grid(id="grid")
        self._metric_widgets: list[MetricTable] = []
        self._cooling_widgets: list[object] = []
        self._timer = None

    # -- layout ----------------------------------------------------------

    def _build_widgets(self) -> None:
        """(Re)create grid widgets from the current config layout."""
        placements = self.cfg.widget_placements()
        self._metric_widgets.clear()
        self._cooling_widgets.clear()
        self._grid.remove_children()

        max_col = 0
        ordered: list[tuple[int, int, str, dict]] = []
        for name, spec in placements.items():
            ordered.append((spec["row"], spec["col"], name, spec))
            max_col = max(max_col, spec["col"] + spec["colspan"])
        columns = max(self.cfg.layout_columns, max_col, 1)
        self._grid.styles.grid_size_columns = columns

        for _row, _col, name, spec in sorted(ordered):
            widget = self._make_widget(name)
            if widget is None:
                continue
            if spec["colspan"] > 1:
                widget.styles.column_span = spec["colspan"]
            if spec["rowspan"] > 1:
                widget.styles.row_span = spec["rowspan"]
            self._grid.mount(widget)
            if isinstance(widget, MetricTable):
                if hasattr(widget, "update_metrics"):
                    self._metric_widgets.append(widget)
                if hasattr(widget, "update_cooling"):
                    self._cooling_widgets.append(widget)
            elif isinstance(widget, ModeSwitcherWidget):
                self._cooling_widgets.append(widget)

    def _make_widget(self, name: str):
        cfg = self.cfg
        if name == "cpu":
            return CpuWidget(cfg)
        m = re.fullmatch(r"gpu(\d+)", name)
        if m:
            return GpuWidget(cfg, index=int(m.group(1)))
        if name == "system":
            return SystemWidget(cfg)
        if name == "aqua":
            return AquaWidget(cfg)
        if name == "fans":
            return FansWidget(cfg)
        if name == "power_avg":
            return PowerAvgWidget(cfg)
        if name == "mode_switcher":
            return ModeSwitcherWidget(cfg, self._apply_mode)
        return None

    def compose(self) -> ComposeResult:
        yield self._grid
        yield Footer()

    # -- lifecycle ---------------------------------------------------------

    def on_mount(self) -> None:
        self._apply_theme()
        self._build_widgets()
        self.cfg.on_reload(self._on_config_reload)
        self._start_timer()
        self._poll()

    def _start_timer(self) -> None:
        if self._timer is not None:
            self._timer.stop()
        self._timer = self.set_interval(
            self.cfg.poll_interval_ms / 1000.0, self._poll, pause=False
        )

    def _apply_theme(self) -> None:
        self.screen.styles.background = self.cfg.colors.get("background", "#0b1220")

    def _on_config_reload(self, cfg: SharedConfig) -> None:
        # Called from _poll on the main (event-loop) thread — no thread hop.
        self._apply_theme()
        self.cc = CoolerControlClient(
            host=cfg.cc_host, port=cfg.cc_port,
            token=cfg.cc_token, password=cfg.cc_password,
            timeout=cfg.cc_timeout,
        )
        self._build_widgets()
        self._start_timer()
        self._poll()

    # -- polling -----------------------------------------------------------

    def _poll(self) -> None:
        if self.cfg.check_reload():
            return  # reload callback re-polls; skip this tick
        self._collect()

    @work(thread=True, exclusive=True)
    def _collect(self) -> None:
        snap = self.collector.sample()
        cooling = self.cc.snapshot()
        self.call_from_thread(self._render, snap, cooling)

    def _render(self, snap, cooling: CoolingSnapshot) -> None:
        # cooling first: PowerAvg reads coolant before rendering its table
        for w in self._cooling_widgets:
            w.update_cooling(cooling)
        for w in self._metric_widgets:
            w.update_metrics(snap)
        if self.cfg.last_error:
            self.sub_title = "config error"
        elif not cooling.connected:
            self.sub_title = "coolercontrol offline"
        else:
            self.sub_title = f"v{__version__}"

    # -- actions -------------------------------------------------------------

    def _apply_mode(self, mode_uid: str, name: str) -> None:
        """Entry point from the mode switcher. Returns instantly; the actual
        POST runs in a worker thread so a slow daemon can't freeze the TUI."""
        self._apply_mode_worker(mode_uid, name)

    @work(thread=True)
    def _apply_mode_worker(self, mode_uid: str, name: str) -> None:
        try:
            self.cc.set_active_mode(mode_uid)
        except CCUnavailable as exc:
            self.call_from_thread(self.notify, str(exc), severity="error")
            return
        self.call_from_thread(self.notify, f"mode applied: {name}")
        self.call_from_thread(self._poll)

    def action_reset_minmax(self) -> None:
        self.collector.reset_minmax()
        self.notify("min/max + averages reset")

    def action_focus_modes(self) -> None:
        for w in self._cooling_widgets:
            if isinstance(w, ModeSwitcherWidget):
                w.focus()
                self.notify("mode switcher — ↑↓ select, Enter applies", timeout=2)
                return


def main() -> None:
    import argparse
    from pathlib import Path

    parser = argparse.ArgumentParser(prog="hazyhud", description="HazyHud v2 TUI")
    parser.add_argument("--init-config", action="store_true",
                        help="write a starter config to ~/.config/hazyhud/config.yaml and exit")
    parser.add_argument("--config", type=Path, default=None, help="config file path")
    args = parser.parse_args()

    if args.init_config:
        from ..config import write_default_config, default_config_path
        config_path = args.config or default_config_path()
        defaults_path = config_path.parent / "config-defaults.yaml"
        result = write_default_config(args.config)
        if result == defaults_path:
            print(f"{config_path} already exists (not overwritten)")
        else:
            print(f"wrote {config_path}")
        print(f"wrote {defaults_path} (read-only reference)")
        return

    app = HazyHudApp(SharedConfig(args.config))
    app.run()


if __name__ == "__main__":
    main()
