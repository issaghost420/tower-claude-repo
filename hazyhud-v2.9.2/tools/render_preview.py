#!/usr/bin/env python3
"""Dev preview — render the Qt HUD with fake hardware data, save a PNG.

No GPU, no CoolerControl daemon, no display needed. Runs offscreen:

    QT_QPA_PLATFORM=offscreen python3 tools/render_preview.py [out.png] [WIDTH HEIGHT] [--config PATH]

Defaults: preview.png at 1600x640, real config file if one exists.
The values mirror the 9-1-26 mock so screenshots compare 1:1.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from hazyhud.models import (  # noqa: E402
    CoolingMode,
    CoolingSnapshot,
    CpuMetrics,
    DiskMetrics,
    FanReading,
    GpuMetrics,
    MetricsSnapshot,
    RamMetrics,
    SystemMetrics,
    TempReading,
)


def fake_metrics() -> MetricsSnapshot:
    return MetricsSnapshot(
        cpu=CpuMetrics(
            temp=68.6, load=6.9, power=84.3,
            min_temp=59.5, max_temp=77.1, min_load=0.0, max_load=68.8,
            min_power=39.5, max_power=183.1,
            avg_power=83, avg_power_15m=87, avg_15m_coverage=1.0,
        ),
        gpus=[
            GpuMetrics(
                index=0, name="NVIDIA GeForce RTX 5090",
                temp=41.0, load=11.0, power=77.1, vram_used=26.5, vram_total=32,
                min_temp=38.0, max_temp=61.0, min_load=2.0, max_load=100.0,
                min_power=55.3, max_power=401.3,
                avg_power=76, avg_power_15m=77, avg_15m_coverage=1.0,
            ),
            GpuMetrics(
                index=1, name="NVIDIA GeForce RTX 5090",
                temp=35.0, load=0.0, power=22.2, vram_used=30.6, vram_total=32,
                min_temp=35.0, max_temp=56.0, min_load=0.0, max_load=98.0,
                min_power=20.7, max_power=473.9,
                avg_power=24, avg_power_15m=22, avg_15m_coverage=1.0,
            ),
        ],
        ram=RamMetrics(used_gb=67.8, free_gb=30.2, total_gb=98, percent=69, temp=52.2),
        disk=DiskMetrics(read_mbs=0.1, write_mbs=6.0),
        system=SystemMetrics(uptime_s=3 * 86400 + 14 * 3600 + 47 * 60,
                             session_s=6 * 3600 + 23 * 60),
        rapl_available=True,
        nvidia_available=True,
    )


def fake_cooling() -> CoolingSnapshot:
    fans = [
        FanReading("u1", "Aquacomputer OCTO", f"fan{i}", f"Fan {i} speed",
                   duty=d, rpm=r)
        for i, (d, r) in enumerate(
            [(57, 1217), (51, 1506), (57, 842), (51, 1432),
             (57, 890), (51, 965), (57, 1071), (37, 1414)], start=1)
    ]
    fans.append(FanReading("u1", "Aquacomputer OCTO", "flow", "Flow speed", duty=None, rpm=0))
    return CoolingSnapshot(
        connected=True,
        fans=fans,
        temps=[
            TempReading("u1", "Aquacomputer OCTO", "t2", "Sensor 2", 35.9),
            TempReading("u1", "Aquacomputer OCTO", "t3", "Sensor 3", 36.3),
            TempReading("u1", "Aquacomputer OCTO", "t4", "Sensor 4", 36.1),
        ],
        modes=[
            CoolingMode("m1", "water-temp-round-2-5-19-26"),
            CoolingMode("m2", "updated-6-17-26"),
            CoolingMode("m3", "6-23-update"),
            CoolingMode("m4", "triple-sensor"),
        ],
        active_mode_uid="m4",
    )


class FakeCollector:
    def sample(self) -> MetricsSnapshot:
        return fake_metrics()

    def reset_minmax(self) -> None:
        pass


class FakeCC:
    def snapshot(self) -> CoolingSnapshot:
        return fake_cooling()

    def set_active_mode(self, uid: str) -> None:
        pass


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("preview.png")
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 1600
    height = int(sys.argv[3]) if len(sys.argv) > 3 else 640
    config_path = None
    if "--config" in sys.argv:
        config_path = Path(sys.argv[sys.argv.index("--config") + 1])

    from PySide6.QtWidgets import QApplication

    import hazyhud.qt.app as qtapp
    from hazyhud.config import SharedConfig

    # Swap the hardware-facing pieces for fakes *before* the window is built,
    # so even the live poll timer feeds fake data.
    qtapp.HazyHudCollector = FakeCollector
    qtapp.CoolerControlClient = lambda **kwargs: FakeCC()  # noqa: E731

    app = QApplication([])
    window = qtapp.HazyHudWindow(SharedConfig(config_path))
    window.resize(width, height)
    window.show()
    window._render(fake_metrics(), fake_cooling())
    app.processEvents()
    window.grab().save(str(out))
    print(f"wrote {out} ({width}x{height})")


if __name__ == "__main__":
    main()
