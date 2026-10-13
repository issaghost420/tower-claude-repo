"""Shared data models for HazyHud v2.

One snapshot type consumed identically by the Textual TUI and the (future)
Qt frontend. Everything here is a plain dataclass: JSON-serializable with
``dataclasses.asdict`` if a transport layer is ever wrapped around the
collector.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Optional


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


# ---------------------------------------------------------------------------
# Collector-side models (host metrics)
# ---------------------------------------------------------------------------


@dataclass
class CpuMetrics:
    temp: Optional[float] = None            # °C
    load: Optional[float] = None            # %
    power: Optional[float] = None           # W (RAPL package power)
    min_temp: Optional[float] = None
    max_temp: Optional[float] = None
    min_load: Optional[float] = None
    max_load: Optional[float] = None
    min_power: Optional[float] = None
    max_power: Optional[float] = None
    avg_power: Optional[float] = None       # lifetime time-weighted average
    avg_power_15m: Optional[float] = None   # rolling 15-minute average
    avg_15m_coverage: float = 0.0           # 0..1 — how much of the window has data


@dataclass
class GpuMetrics:
    index: int = 0
    name: str = ""
    temp: Optional[float] = None            # °C
    load: Optional[float] = None            # %
    power: Optional[float] = None           # W
    vram_used: Optional[float] = None       # GB
    vram_total: Optional[float] = None      # GB
    min_temp: Optional[float] = None
    max_temp: Optional[float] = None
    min_load: Optional[float] = None
    max_load: Optional[float] = None
    min_power: Optional[float] = None
    max_power: Optional[float] = None
    avg_power: Optional[float] = None
    avg_power_15m: Optional[float] = None
    avg_15m_coverage: float = 0.0


@dataclass
class RamMetrics:
    used_gb: Optional[float] = None
    free_gb: Optional[float] = None         # psutil "available" (incl. reclaimable) — intentional
    total_gb: Optional[float] = None
    percent: Optional[float] = None
    temp: Optional[float] = None            # DDR5 spd5118 sensor, °C


@dataclass
class DiskMetrics:
    read_mbs: Optional[float] = None
    write_mbs: Optional[float] = None


@dataclass
class SystemMetrics:
    uptime_s: float = 0.0
    session_s: float = 0.0


@dataclass
class MetricsSnapshot:
    """One full collection pass. The single payload every frontend renders."""

    timestamp: str = field(default_factory=_now_iso)
    cpu: CpuMetrics = field(default_factory=CpuMetrics)
    gpus: list[GpuMetrics] = field(default_factory=list)
    ram: RamMetrics = field(default_factory=RamMetrics)
    disk: DiskMetrics = field(default_factory=DiskMetrics)
    system: SystemMetrics = field(default_factory=SystemMetrics)
    # Probed capability flags so UIs can explain N/A instead of guessing.
    rapl_available: bool = False
    nvidia_available: bool = False


# ---------------------------------------------------------------------------
# CoolerControl-side models (fans, coolant, modes)
# ---------------------------------------------------------------------------


@dataclass
class FanReading:
    device_uid: str
    device_name: str
    channel: str                       # channel name as the daemon reports it
    label: str                         # user label from /devices if set, else channel name
    duty: Optional[float] = None       # %
    rpm: Optional[float] = None
    watts: Optional[float] = None


@dataclass
class TempReading:
    device_uid: str
    device_name: str
    sensor: str
    label: str                         # user label from /devices if set, else sensor name
    temp: float                        # °C


@dataclass
class CoolingMode:
    uid: str
    name: str


@dataclass
class CoolingSnapshot:
    """Everything the UI needs from CoolerControl in one poll."""

    connected: bool = False
    fans: list[FanReading] = field(default_factory=list)
    temps: list[TempReading] = field(default_factory=list)
    modes: list[CoolingMode] = field(default_factory=list)
    active_mode_uid: Optional[str] = None
    daemon_version: Optional[str] = None
    error: Optional[str] = None
