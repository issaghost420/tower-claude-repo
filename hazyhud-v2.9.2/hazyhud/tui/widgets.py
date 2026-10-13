"""Textual widgets for the HazyHud TUI.

Every widget is a thin renderer over the shared snapshots: it receives a
``MetricsSnapshot`` and/or ``CoolingSnapshot`` plus the live ``SharedConfig``
(for thresholds/colors) and re-renders a Rich table. Widgets hold no
collector state of their own — min/max/averages live in the data layer.

The visual language is the original: square cyan boxes, teal labels,
green values, violet mins, amber maxes, threshold-driven warn/crit recoloring.
"""

from __future__ import annotations

from typing import Optional

from rich import box
from rich.table import Table
from rich.text import Text
from textual.widgets import OptionList, Static
from textual.widgets.option_list import Option

from ..config import SharedConfig
from ..models import CoolingSnapshot, GpuMetrics, MetricsSnapshot


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


class MetricTable(Static):
    """Base: a Static that renders a square Rich table with config colors."""

    def __init__(self, cfg: SharedConfig, title: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self.cfg = cfg
        self.title = title

    def _new_table(self, columns: list[str]) -> Table:
        colors = self.cfg.colors
        table = Table(
            box=box.SQUARE,
            border_style=colors.get("border", "#38bdf8"),
            header_style=colors.get("text_label", "#2dd4bf"),
            expand=True,
            pad_edge=False,
            show_edge=True,
        )
        table.add_column(self.title, style=colors.get("text_label", "#2dd4bf"))
        for col in columns:
            table.add_column(col, justify="right")
        return table

    def _styled(self, metric: str, value: Optional[float], text: str) -> Text:
        return Text(text, style=self.cfg.color_of(metric, value))

    def _dim(self, text: str) -> Text:
        return Text(text, style=self.cfg.colors.get("text_dim", "#818cf8"))

    def _max_style(self, text: str) -> Text:
        return Text(text, style=self.cfg.colors.get("text_max", "#fbbf24"))


class CpuWidget(MetricTable):
    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "CPU", **kwargs)

    def update_metrics(self, snap: MetricsSnapshot) -> None:
        c = snap.cpu
        table = self._new_table(["Current", "Min", "Max"])
        for label, metric, cur, mn, mx, dec in (
            ("Temp °C", "cpu_temp", c.temp, c.min_temp, c.max_temp, 1),
            ("Load %", "cpu_load", c.load, c.min_load, c.max_load, 1),
            ("Power W", "cpu_power", c.power, c.min_power, c.max_power, 1),
        ):
            table.add_row(
                label,
                self._styled(metric, cur, _fmt(cur, dec)),
                self._dim(_fmt(mn, dec)),
                self._max_style(_fmt(mx, dec)),
            )
        self.update(table)


class GpuWidget(MetricTable):
    def __init__(self, cfg: SharedConfig, index: int, **kwargs) -> None:
        super().__init__(cfg, f"GPU {index}", **kwargs)
        self.index = index

    def update_metrics(self, snap: MetricsSnapshot) -> None:
        g: Optional[GpuMetrics] = next(
            (x for x in snap.gpus if x.index == self.index), None
        )
        if g is None:
            self.title = f"GPU {self.index}"
            self.update(Text("not detected", style=self.cfg.colors.get("text_dim", "")))
            return
        short = g.name.replace("NVIDIA", "").replace("GeForce", "").strip()
        self.title = f"GPU {g.index} ({short})" if short else f"GPU {g.index}"
        table = self._new_table(["Current", "Min", "Max"])
        for label, metric, cur, mn, mx in (
            ("Temp °C", "gpu_temp", g.temp, g.min_temp, g.max_temp),
            ("Load %", "gpu_load", g.load, g.min_load, g.max_load),
            ("Power W", "gpu_power", g.power, g.min_power, g.max_power),
        ):
            table.add_row(
                label,
                self._styled(metric, cur, _fmt(cur)),
                self._dim(_fmt(mn)),
                self._max_style(_fmt(mx)),
            )
        table.add_row(
            "VRAM",
            Text(
                f"{_fmt(g.vram_used)}/{_fmt(g.vram_total, 0)} GB",
                style=self.cfg.colors.get("text_normal", ""),
            ),
            "",
            "",
        )
        self.update(table)


class SystemWidget(MetricTable):
    """RAM (+ DDR5 temp), disk R/W, uptime, session — the v1 'System' panel."""

    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "System", **kwargs)

    def update_metrics(self, snap: MetricsSnapshot) -> None:
        colors = self.cfg.colors
        r, dk, sys = snap.ram, snap.disk, snap.system
        table = self._new_table(["Value", "", ""])
        table.add_row(
            "RAM",
            self._styled(
                "ram_percent",
                r.percent,
                f"{_fmt(r.used_gb)}/{_fmt(r.total_gb, 0)} GB",
            ),
            self._dim(f"{_fmt(r.percent, 0)}%"),
            self._dim(f"DDR5 {_fmt(r.temp)}°C" if r.temp is not None else ""),
        )
        table.add_row(
            "Read",
            Text(f"{_fmt(dk.read_mbs)} MB/s", style=colors.get("text_normal", "")),
            "",
            "",
        )
        table.add_row(
            "Write",
            Text(f"{_fmt(dk.write_mbs)} MB/s", style=colors.get("text_normal", "")),
            "",
            Text(f"Uptime  {_duration(sys.uptime_s)}", style=colors.get("text_normal", "")),
        )
        table.add_row(
            "",
            "",
            "",
            Text(f"Session {_duration(sys.session_s)}", style=colors.get("text_dim", "")),
        )
        self.update(table)


class AquaWidget(MetricTable):
    """Coolant + loop temps from the Octo (or whichever CC device is matched).

    Shows every temp sensor the matched device reports — the 3 Octo temp
    sensors included — with coolant threshold coloring on the primary one.
    """

    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "Coolant", **kwargs)

    def update_cooling(self, snap: CoolingSnapshot) -> None:
        colors = self.cfg.colors
        match = self.cfg.get("coolercontrol", "aqua_device_match", default="octo")
        table = self._new_table(["Temp", "", ""])
        if not snap.connected:
            table.add_row(self._dim("daemon offline"), "", "", "")
        else:
            temps = [t for t in snap.temps
                     if not match or match.lower() in t.device_name.lower()]
            if not temps:
                table.add_row(self._dim(f"no temps on '{match}'"), "", "", "")
            for i, t in enumerate(temps):
                styled = self._styled("water_temp", t.temp, f"{t.temp:.1f} °C")
                table.add_row(t.label, styled, "", "" if i else t.device_name[:18])
        self.update(table)


class FansWidget(MetricTable):
    """Fan grid: label | duty% | rpm, laid out two fans per row (1-8 like the Octo)."""

    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "Fans", **kwargs)

    def update_cooling(self, snap: CoolingSnapshot) -> None:
        colors = self.cfg.colors
        match = self.cfg.get("coolercontrol", "fan_device_match", default="")
        table = self._new_table(["%", "RPM", "", "%", "RPM"])
        if not snap.connected:
            table.add_row(self._dim("daemon offline"), "", "", "", "", "")
        else:
            fans = [f for f in snap.fans
                    if not match or match.lower() in f.device_name.lower()]
            if not fans:
                table.add_row(self._dim("no fan channels"), "", "", "", "", "")
            # two fans per row: (i, i+half) pairing reads 1,5 / 2,6 / ... like the sketch
            half = (len(fans) + 1) // 2
            for i in range(half):
                left = fans[i]
                right = fans[i + half] if i + half < len(fans) else None

                def cells(f):
                    if f is None:
                        return "", "", ""
                    return (
                        f.label,
                        Text(_fmt_int(f.duty), style=colors.get("text_normal", "")),
                        self._dim(_fmt_int(f.rpm)),
                    )

                row = cells(left)
                rrow = cells(right)
                table.add_row(row[0], row[1], row[2], rrow[0], rrow[1], rrow[2])
        self.update(table)


class PowerAvgWidget(MetricTable):
    """HW | avg | 15m — the power average table, with warmup honesty."""

    def __init__(self, cfg: SharedConfig, **kwargs) -> None:
        super().__init__(cfg, "Power", **kwargs)
        self._coolant: Optional[float] = None

    def update_metrics(self, snap: MetricsSnapshot) -> None:
        table = self._new_table(["avg", "15m"])
        rows: list[tuple[str, Optional[float], Optional[float], float, str]] = [
            ("CPU W", snap.cpu.avg_power, snap.cpu.avg_power_15m,
             snap.cpu.avg_15m_coverage, "cpu_power"),
        ]
        for g in snap.gpus:
            rows.append((f"GPU {g.index} W", g.avg_power, g.avg_power_15m,
                         g.avg_15m_coverage, "gpu_power"))
        if self._coolant is not None:
            rows.append(("H₂O °C", None, None, 1.0, "water_temp"))
        for label, avg, avg15, coverage, metric in rows:
            if label == "H₂O °C":
                table.add_row(label, "", self._styled(metric, self._coolant,
                                                      _fmt(self._coolant)))
                continue
            warm = coverage >= 0.98
            avg15_text = _fmt(avg15, 0) if warm else (
                f"~{_fmt(avg15, 0)}" if avg15 is not None else "—")
            table.add_row(
                label,
                Text(_fmt(avg, 0), style=self.cfg.colors.get("text_dim", "")),
                self._styled(metric, avg15, avg15_text),
            )
        self.update(table)

    def update_cooling(self, snap: CoolingSnapshot) -> None:
        match = self.cfg.get("coolercontrol", "aqua_device_match", default="octo")
        temps = [t for t in snap.temps
                 if snap.connected and (not match or match.lower() in t.device_name.lower())]
        self._coolant = temps[0].temp if temps else None


class ModeSwitcherWidget(Static):
    """Cooling modes from CoolerControl. Enter applies the highlighted mode.

    ``apply_callback(uid, name)`` must be non-blocking — the app runs the
    actual daemon POST in a worker thread.
    """

    def __init__(self, cfg: SharedConfig, apply_callback, **kwargs) -> None:
        super().__init__(**kwargs)
        self.cfg = cfg
        self._apply = apply_callback
        self._list = OptionList()
        self._modes = []

    def compose(self):
        yield self._list

    def focus(self, scroll_visible: bool = True):
        # Static isn't focusable — forward to the option list so the 'm'
        # key actually lands somewhere visible.
        self._list.focus(scroll_visible)
        return self

    def update_cooling(self, snap: CoolingSnapshot) -> None:
        colors = self.cfg.colors
        self._modes = list(snap.modes)
        self._list.clear_options()
        if not snap.connected:
            self._list.add_option(Option(Text("daemon offline",
                                              style=colors.get("text_dim", "")),
                                         disabled=True))
            return
        if not self._modes:
            self._list.add_option(Option(Text("no modes saved in CoolerControl",
                                              style=colors.get("text_dim", "")),
                                         disabled=True))
            return
        for m in self._modes:
            active = m.uid == snap.active_mode_uid
            marker = "▸ " if active else "  "
            style = colors.get("text_normal", "") if active else ""
            self._list.add_option(Option(Text(f"{marker}{m.name}", style=style), id=m.uid))

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        mode = next((m for m in self._modes if m.uid == event.option_id), None)
        if mode is None:
            return
        self._apply(mode.uid, mode.name)
