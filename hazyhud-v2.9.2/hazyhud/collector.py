"""HazyHudCollector — the standalone host-metrics data layer.

Importable by anything. No transport, no frontend knowledge, no globals:
one instance per process that wants to sample the host.

Data sources
------------
- CPU load %         psutil.cpu_percent (non-blocking; primed at init)
- CPU temp °C        psutil.sensors_temperatures (coretemp "Core" avg,
                     k10temp fallback for AMD)
- CPU power W        RAPL energy_uj delta via /sys/class/powercap. The
                     driver is misnamed "intel-rapl" but serves AMD Ryzen
                     9000 through intel_rapl_msr/intel_rapl_common. Probed
                     at startup; degrades to None on hosts without it.
- GPU x N            nvidia-smi subprocess (2 s timeout), by index
- RAM                psutil.virtual_memory
- DDR5 temp          hwmon spd5118 sensor scan
- Disk R/W           psutil.disk_io_counters deltas
- Uptime / session   psutil.boot_time / collector start

The 15-minute power average bug from v1 (GPU0 reading ~80 W while GPU1 read
~305 W under even pipeline-parallel load) is fixed here at the sampling
layer, not the rendering layer:

1. Every device is sampled unconditionally on every ``sample()`` call — no
   code path can skip one GPU and let its ring go stale.
2. Averages are **time-weighted**, not sample-count means. If a poll tick
   is delayed (slow nvidia-smi query, system hiccup) a naive mean silently
   over-weights the pre-stall value. Weighting each sample by the wall time
   it represented makes the number honest regardless of tick jitter.
3. Window coverage is reported so the UI can dim a 15-minute average that
   is still warming up instead of presenting a misleading number as fact.
"""

from __future__ import annotations

import glob
import os
import subprocess
import time
from collections import deque
from typing import Optional

import psutil

from .models import (
    CpuMetrics,
    DiskMetrics,
    GpuMetrics,
    MetricsSnapshot,
    RamMetrics,
    SystemMetrics,
)

_NVIDIA_SMI_FIELDS = (
    "index,name,temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total"
)
_NVIDIA_SMI_TIMEOUT_S = 2.0
_POWERCAP_ROOT = "/sys/class/powercap"
_HWMON_ROOT = "/sys/class/hwmon"
_WINDOW_15M_S = 900.0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


class MinMaxTracker:
    """Running min/max for a set of float keys. Ignores None samples."""

    def __init__(self) -> None:
        self._min: dict[str, float] = {}
        self._max: dict[str, float] = {}

    def update(self, key: str, value: Optional[float]) -> None:
        if value is None:
            return
        value = max(0.0, float(value))  # clamp >= 0, as v1 did
        if key not in self._min or value < self._min[key]:
            self._min[key] = value
        if key not in self._max or value > self._max[key]:
            self._max[key] = value

    def get(self, key: str) -> tuple[Optional[float], Optional[float]]:
        return self._min.get(key), self._max.get(key)

    def reset(self) -> None:
        self._min.clear()
        self._max.clear()


class TimeWeightedAverage:
    """Rolling time-weighted average over a sliding window.

    Samples are (monotonic_ts, value). Each sample's weight is the time from
    the previous sample to it (prev-value hold), so irregular sampling cannot
    skew the result — the core of the v1 GPU0 average bug.
    """

    def __init__(self, window_s: float) -> None:
        self.window_s = window_s
        self._samples: deque[tuple[float, float]] = deque()
        self._last_ts: Optional[float] = None

    def add(self, value: float, ts: Optional[float] = None) -> None:
        ts = time.monotonic() if ts is None else ts
        self._samples.append((ts, float(value)))
        self._last_ts = ts
        self._prune(ts)

    def _prune(self, now: float) -> None:
        cutoff = now - self.window_s
        while len(self._samples) > 1 and self._samples[1][0] <= cutoff:
            self._samples.popleft()
        # Keep one sample at/left of the cutoff as the window's left edge.
        if self._samples and self._samples[0][0] > cutoff and len(self._samples) > 1:
            pass  # window simply isn't full yet; coverage reflects this

    def average(self, now: Optional[float] = None) -> Optional[float]:
        if not self._samples:
            return None
        now = time.monotonic() if now is None else now
        cutoff = now - self.window_s
        weighted = 0.0
        span = 0.0
        prev_ts, prev_val = self._samples[0]
        prev_ts = max(prev_ts, cutoff)
        for ts, val in list(self._samples)[1:]:
            if ts <= cutoff:
                prev_ts, prev_val = max(ts, cutoff), val
                continue
            dt = ts - prev_ts
            if dt > 0:
                weighted += prev_val * dt
                span += dt
            prev_ts, prev_val = ts, val
        # extend the last sample's hold to "now"
        if now > prev_ts:
            weighted += prev_val * (now - prev_ts)
            span += now - prev_ts
        if span <= 0:
            return self._samples[-1][1]
        return weighted / span

    def coverage(self, now: Optional[float] = None) -> float:
        """Fraction of the window (0..1) actually covered by samples."""
        if not self._samples:
            return 0.0
        now = time.monotonic() if now is None else now
        covered = now - max(self._samples[0][0], now - self.window_s)
        return max(0.0, min(1.0, covered / self.window_s))


class LifetimeAverage:
    """Time-weighted average since collector start."""

    def __init__(self) -> None:
        self._last_ts: Optional[float] = None
        self._last_val: Optional[float] = None
        self._weighted = 0.0
        self._span = 0.0

    def add(self, value: float, ts: Optional[float] = None) -> None:
        ts = time.monotonic() if ts is None else ts
        if self._last_ts is not None and self._last_val is not None:
            dt = ts - self._last_ts
            if dt > 0:
                self._weighted += self._last_val * dt
                self._span += dt
        self._last_ts, self._last_val = ts, float(value)

    def average(self) -> Optional[float]:
        if self._span <= 0:
            return self._last_val
        return self._weighted / self._span

    def reset(self) -> None:
        self.__init__()


# ---------------------------------------------------------------------------
# Collector
# ---------------------------------------------------------------------------


class HazyHudCollector:
    """Samples the host. Create once per process, call ``sample()`` on a tick."""

    def __init__(self) -> None:
        self._started = time.time()
        self._minmax = MinMaxTracker()
        self._avg_15m: dict[str, TimeWeightedAverage] = {}
        self._avg_life: dict[str, LifetimeAverage] = {}

        # Prime cpu_percent so the first real sample isn't the meaningless
        # "since boot" figure.
        psutil.cpu_percent(interval=None)

        # RAPL probing — do it once, fail soft.
        self._rapl_energy_path: Optional[str] = None
        self._rapl_max_range_uj: Optional[int] = None
        self._rapl_last: Optional[tuple[float, int]] = None
        self._probe_rapl()

        # nvidia-smi probing.
        self._nvidia_available = self._probe_nvidia()

        # spd5118 DDR5 temp sensor.
        self._spd5118_temp_path: Optional[str] = self._find_hwmon_temp("spd5118")

        # Disk I/O baseline.
        self._disk_last: Optional[tuple[float, int, int]] = None

    # -- probing ---------------------------------------------------------

    def _probe_rapl(self) -> None:
        """Find a package-level RAPL energy counter, whatever the CPU vendor."""
        try:
            for entry in sorted(os.listdir(_POWERCAP_ROOT)):
                base = os.path.join(_POWERCAP_ROOT, entry)
                if not entry.startswith("intel-rapl:"):
                    continue  # top-level domains only, not subzones
                energy = os.path.join(base, "energy_uj")
                if not os.path.isfile(energy) or not os.access(energy, os.R_OK):
                    continue
                name_path = os.path.join(base, "name")
                name = ""
                try:
                    with open(name_path, encoding="ascii") as fh:
                        name = fh.read().strip()
                except OSError:
                    pass
                # Prefer the package domain; accept an unnamed domain 0.
                if name in ("package-0", "package", "") or entry.endswith(":0"):
                    self._rapl_energy_path = energy
                    try:
                        with open(os.path.join(base, "max_energy_range_uj")) as fh:
                            self._rapl_max_range_uj = int(fh.read().strip())
                    except (OSError, ValueError):
                        self._rapl_max_range_uj = None
                    return
        except OSError:
            pass

    def _probe_nvidia(self) -> bool:
        try:
            subprocess.run(
                ["nvidia-smi", "--query-gpu=index", "--format=csv,noheader"],
                capture_output=True,
                timeout=_NVIDIA_SMI_TIMEOUT_S,
                check=True,
            )
            return True
        except (OSError, subprocess.SubprocessError):
            return False

    @staticmethod
    def _find_hwmon_temp(name_fragment: str) -> Optional[str]:
        """Locate the first temp*_input of the hwmon device named *name_fragment*."""
        try:
            for hwmon in sorted(glob.glob(os.path.join(_HWMON_ROOT, "hwmon*"))):
                try:
                    with open(os.path.join(hwmon, "name"), encoding="ascii") as fh:
                        if name_fragment not in fh.read().strip().lower():
                            continue
                except OSError:
                    continue
                temps = sorted(glob.glob(os.path.join(hwmon, "temp*_input")))
                if temps:
                    return temps[0]
        except OSError:
            pass
        return None

    # -- individual samplers ---------------------------------------------

    def _cpu_load(self) -> Optional[float]:
        try:
            return float(psutil.cpu_percent(interval=None))  # non-blocking
        except Exception:
            return None

    @staticmethod
    def _cpu_temp() -> Optional[float]:
        try:
            temps = psutil.sensors_temperatures()
        except Exception:
            return None
        if not temps:
            return None
        # Intel: average of coretemp "Core" entries.
        core_cores = [
            e.current
            for e in temps.get("coretemp", [])
            if e.label and e.label.lower().startswith("core")
        ]
        if core_cores:
            return sum(core_cores) / len(core_cores)
        # AMD: k10temp — prefer Tctl/Tdie, else first entry.
        k10 = temps.get("k10temp") or []
        for preferred in ("tctl", "tdie"):
            for e in k10:
                if e.label and e.label.lower() == preferred:
                    return float(e.current)
        if k10:
            return float(k10[0].current)
        # Last resort: first sensor of the first chip.
        for entries in temps.values():
            if entries:
                return float(entries[0].current)
        return None

    def _cpu_power(self) -> Optional[float]:
        """RAPL package watts = ΔµJ / Δt, with 32-bit wraparound handling."""
        if not self._rapl_energy_path:
            return None
        try:
            with open(self._rapl_energy_path, encoding="ascii") as fh:
                energy_uj = int(fh.read().strip())
        except (OSError, ValueError):
            return None
        now = time.monotonic()
        if self._rapl_last is None:
            self._rapl_last = (now, energy_uj)
            return None  # need two reads; next tick gets a real number
        prev_ts, prev_uj = self._rapl_last
        self._rapl_last = (now, energy_uj)
        dt = now - prev_ts
        if dt <= 0:
            return None
        duj = energy_uj - prev_uj
        if duj < 0:
            if self._rapl_max_range_uj:
                duj += self._rapl_max_range_uj  # counter wrapped
            else:
                return None
        return duj / dt / 1e6

    def _gpus(self) -> list[GpuMetrics]:
        if not self._nvidia_available:
            return []
        try:
            out = subprocess.run(
                [
                    "nvidia-smi",
                    f"--query-gpu={_NVIDIA_SMI_FIELDS}",
                    "--format=csv,noheader,nounits",
                ],
                capture_output=True,
                timeout=_NVIDIA_SMI_TIMEOUT_S,
                text=True,
                check=True,
            )
        except (OSError, subprocess.SubprocessError):
            return []
        gpus: list[GpuMetrics] = []
        for line in out.stdout.strip().splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 7:
                continue

            def num(s: str) -> Optional[float]:
                try:
                    return float(s)
                except (ValueError, TypeError):
                    return None

            gpus.append(
                GpuMetrics(
                    index=int(num(parts[0]) or 0),
                    name=parts[1],
                    temp=num(parts[2]),
                    load=num(parts[3]),
                    power=num(parts[4]),
                    vram_used=(num(parts[5]) or 0) / 1024.0,  # MB → GB
                    vram_total=(num(parts[6]) or 0) / 1024.0,
                )
            )
        gpus.sort(key=lambda g: g.index)
        return gpus

    @staticmethod
    def _ram() -> RamMetrics:
        try:
            vm = psutil.virtual_memory()
            return RamMetrics(
                used_gb=vm.used / 1e9,
                free_gb=vm.available / 1e9,  # available incl. reclaimable — intentional
                total_gb=vm.total / 1e9,
                percent=vm.percent,
            )
        except Exception:
            return RamMetrics()

    def _ram_temp(self) -> Optional[float]:
        if not self._spd5118_temp_path:
            return None
        try:
            with open(self._spd5118_temp_path, encoding="ascii") as fh:
                return int(fh.read().strip()) / 1000.0  # millidegrees → °C
        except (OSError, ValueError):
            return None

    def _disk(self) -> DiskMetrics:
        try:
            io = psutil.disk_io_counters()
        except Exception:
            return DiskMetrics()
        if io is None:
            return DiskMetrics()
        now = time.monotonic()
        if self._disk_last is None:
            self._disk_last = (now, io.read_bytes, io.write_bytes)
            return DiskMetrics(read_mbs=0.0, write_mbs=0.0)
        prev_ts, prev_r, prev_w = self._disk_last
        self._disk_last = (now, io.read_bytes, io.write_bytes)
        dt = now - prev_ts
        if dt <= 0:
            return DiskMetrics()
        return DiskMetrics(
            read_mbs=(io.read_bytes - prev_r) / dt / 1e6,
            write_mbs=(io.write_bytes - prev_w) / dt / 1e6,
        )

    # -- power-average bookkeeping -----------------------------------------

    def _track_power(self, key: str, watts: Optional[float]) -> None:
        """Feed a power sample into the lifetime + 15-minute trackers.

        Called unconditionally for every device on every tick — a device that
        reports None is skipped for that tick but its ring is never left to
        go stale relative to its siblings (the v1 failure mode).
        """
        if watts is None:
            return
        self._avg_15m.setdefault(key, TimeWeightedAverage(_WINDOW_15M_S)).add(watts)
        self._avg_life.setdefault(key, LifetimeAverage()).add(watts)

    def _power_stats(
        self, key: str
    ) -> tuple[Optional[float], Optional[float], float]:
        avg_15m = self._avg_15m.get(key)
        avg_life = self._avg_life.get(key)
        return (
            avg_life.average() if avg_life else None,
            avg_15m.average() if avg_15m else None,
            avg_15m.coverage() if avg_15m else 0.0,
        )

    # -- main entry ---------------------------------------------------------

    def sample(self) -> MetricsSnapshot:
        """One full collection pass. Safe to call on any cadence >= ~250 ms."""
        snap = MetricsSnapshot(
            rapl_available=self._rapl_energy_path is not None,
            nvidia_available=self._nvidia_available,
        )

        # CPU
        cpu = CpuMetrics(
            temp=self._cpu_temp(),
            load=self._cpu_load(),
            power=self._cpu_power(),
        )
        self._minmax.update("cpu_temp", cpu.temp)
        self._minmax.update("cpu_load", cpu.load)
        self._minmax.update("cpu_power", cpu.power)
        cpu.min_temp, cpu.max_temp = self._minmax.get("cpu_temp")
        cpu.min_load, cpu.max_load = self._minmax.get("cpu_load")
        cpu.min_power, cpu.max_power = self._minmax.get("cpu_power")
        self._track_power("cpu", cpu.power)
        cpu.avg_power, cpu.avg_power_15m, cpu.avg_15m_coverage = self._power_stats("cpu")
        snap.cpu = cpu

        # GPUs — one unconditional query covers all indices
        for gpu in self._gpus():
            key = f"gpu{gpu.index}"
            self._minmax.update(f"{key}_temp", gpu.temp)
            self._minmax.update(f"{key}_load", gpu.load)
            self._minmax.update(f"{key}_power", gpu.power)
            gpu.min_temp, gpu.max_temp = self._minmax.get(f"{key}_temp")
            gpu.min_load, gpu.max_load = self._minmax.get(f"{key}_load")
            gpu.min_power, gpu.max_power = self._minmax.get(f"{key}_power")
            self._track_power(key, gpu.power)
            gpu.avg_power, gpu.avg_power_15m, gpu.avg_15m_coverage = self._power_stats(key)
            snap.gpus.append(gpu)

        # RAM (+ DDR5 temp)
        snap.ram = self._ram()
        snap.ram.temp = self._ram_temp()

        # Disk
        snap.disk = self._disk()

        # System
        now = time.time()
        snap.system = SystemMetrics(
            uptime_s=now - psutil.boot_time(),
            session_s=now - self._started,
        )
        return snap

    def reset_minmax(self) -> None:
        """Clear min/max and averages (mirrors v1's /api/reset)."""
        self._minmax.reset()
        self._avg_15m.clear()
        self._avg_life.clear()
