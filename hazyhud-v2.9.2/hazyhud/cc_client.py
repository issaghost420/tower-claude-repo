"""CoolerControlClient — read-only monitoring + mode switching over the
CoolerControl daemon REST API (default http://localhost:11987).

Built against the daemon's OpenAPI spec v4.3.1 (shipped in this repo as
``docs_cc_openapi_4.3.1.json``). Endpoints used:

- ``GET  /handshake``               daemon liveness
- ``GET  /devices``                 device metadata (names, temp/channel labels)
- ``GET  /status``                  live temps + channel duty/rpm per device
- ``GET  /modes``                   saved cooling modes
- ``GET  /modes-active``            current/previous active mode uids
- ``POST /modes-active/{uid}``      apply a mode live
- ``GET  /profiles``                saved profiles (informational)

Scope: HazyHud consumes CoolerControl — it does NOT rebuild fan curves,
profile editing, or calibration (that's what CC and its official cctv TUI
are for). The only write this client performs is switching the active Mode.

Auth: newer CoolerControl releases enable access protection by default.
Two supported paths, in priority order:

1. ``token`` — a bearer token (``cc_...``) created in the CC UI under
   Access Protection. Read-only is enough for monitoring; mode switching
   needs write access. Best option.
2. ``password`` — the daemon admin password. The client POSTs ``/login``
   with HTTP Basic, captures the session cookie, and refreshes it on 401.

The client is deliberately dependency-free (urllib). Every public method
raises ``CCUnavailable`` on connection/timeout/parse failure so frontends
can degrade to "daemon offline" instead of crashing.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Optional

from .models import CoolingMode, CoolingSnapshot, FanReading, TempReading


class CCUnavailable(Exception):
    """The daemon is unreachable, timed out, or answered unexpectedly."""


class CCAuthError(CCUnavailable):
    """The daemon requires a token we don't have (or rejected the one we sent)."""


class CoolerControlClient:
    def __init__(
        self,
        host: str = "localhost",
        port: int = 11987,
        token: Optional[str] = None,
        password: Optional[str] = None,
        timeout: float = 2.0,
    ) -> None:
        self.base_url = f"http://{host}:{port}"
        self.token = token
        self.password = password
        self.timeout = timeout
        self._session_cookie: Optional[str] = None
        # Labels are static-ish; refreshed on each snapshot anyway (cheap).
        self._temp_labels: dict[tuple[str, str], str] = {}    # (uid, sensor) -> label
        self._channel_labels: dict[tuple[str, str], str] = {} # (uid, channel) -> label
        self._device_names: dict[str, str] = {}               # uid -> name

    # -- low-level ---------------------------------------------------------

    def _login(self) -> None:
        """Password auth: POST /login with HTTP Basic, keep the session cookie."""
        import base64

        creds = base64.b64encode(f"admin:{self.password}".encode()).decode()
        req = urllib.request.Request(self.base_url + "/login", data=b"", method="POST")
        req.add_header("Authorization", f"Basic {creds}")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                cookie = resp.headers.get("Set-Cookie", "")
                self._session_cookie = cookie.split(";", 1)[0] or None
        except urllib.error.HTTPError as exc:
            raise CCAuthError(
                f"login failed ({exc.code}) — check coolercontrol.password in the config"
            ) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise CCUnavailable(f"login failed: {exc}") from exc
        if not self._session_cookie:
            raise CCAuthError("login returned no session cookie")

    def _open(self, req: urllib.request.Request) -> Any:
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        elif self._session_cookie:
            req.add_header("Cookie", self._session_cookie)
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            set_cookie = resp.headers.get("Set-Cookie")
            if set_cookie and not self.token:
                self._session_cookie = set_cookie.split(";", 1)[0]
            body = resp.read().decode("utf-8")
            return json.loads(body) if body.strip() else {}

    def _request(self, method: str, path: str, payload: Any = None, _retried: bool = False) -> Any:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(self.base_url + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            return self._open(req)
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                # Password path: session may be missing/expired — login once, retry once.
                if self.password and not self.token and not _retried:
                    self._login()
                    return self._request(method, path, payload, _retried=True)
                raise CCAuthError(
                    f"daemon answered {exc.code} for {method} {path} — set "
                    "coolercontrol.token (CC UI → Access Protection; write access "
                    "required for mode switching) or coolercontrol.password"
                ) from exc
            raise CCUnavailable(f"{method} {path} -> HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            raise CCUnavailable(f"{method} {path} failed: {exc}") from exc

    def _get(self, path: str) -> Any:
        return self._request("GET", path)

    def _post(self, path: str, payload: Any = None) -> Any:
        return self._request("POST", path, payload)

    # -- individual endpoints ----------------------------------------------

    def handshake(self) -> bool:
        try:
            self._get("/handshake")
            return True
        except CCUnavailable:
            return False

    def devices(self) -> list[dict]:
        return list(self._get("/devices").get("devices", []))

    def status(self) -> list[dict]:
        """Raw per-device status DTOs (with full status_history)."""
        return list(self._get("/status").get("devices", []))

    def modes(self) -> list[CoolingMode]:
        raw = self._get("/modes").get("modes", [])
        return [CoolingMode(uid=m.get("uid", ""), name=m.get("name", "?")) for m in raw]

    def active_mode(self) -> Optional[str]:
        dto = self._get("/modes-active")
        return dto.get("current_mode_uid") or None

    def set_active_mode(self, mode_uid: str) -> None:
        """Apply a cooling mode live. The only write this client performs."""
        self._post(f"/modes-active/{mode_uid}")

    def profiles(self) -> list[dict]:
        return list(self._get("/profiles").get("profiles", []))

    # -- parsing -------------------------------------------------------------

    def _refresh_metadata(self, devices: list[dict]) -> None:
        self._temp_labels.clear()
        self._channel_labels.clear()
        self._device_names.clear()
        for dev in devices:
            uid = dev.get("uid", "")
            self._device_names[uid] = dev.get("name", uid)
            info = dev.get("info") or {}
            for sensor, tinfo in (info.get("temps") or {}).items():
                label = (tinfo or {}).get("label")
                if label:
                    self._temp_labels[(uid, sensor)] = label
            for channel, cinfo in (info.get("channels") or {}).items():
                label = (cinfo or {}).get("label")
                if label:
                    self._channel_labels[(uid, channel)] = label

    def _latest(self, device_status: dict) -> Optional[dict]:
        history = device_status.get("status_history") or []
        return history[-1] if history else None

    def _parse_fans(self, statuses: list[dict]) -> list[FanReading]:
        fans: list[FanReading] = []
        for dev in statuses:
            uid = dev.get("uid", "")
            name = self._device_names.get(uid, uid)
            latest = self._latest(dev)
            if not latest:
                continue
            for ch in latest.get("channels", []):
                ch_name = ch.get("name", "?")
                duty = ch.get("duty")
                rpm = ch.get("rpm")
                watts = ch.get("watts")
                # A channel with neither duty nor rpm isn't a fan/pump worth showing.
                if duty is None and rpm is None:
                    continue
                label = self._channel_labels.get((uid, ch_name), ch_name)
                # CoolerControl surfaces CPU/GPU *load* as duty-only channels;
                # they're not fans. Drop channels that report a duty but no rpm
                # and whose name/label reads as a load meter.
                blob = f"{ch_name} {label}".lower()
                if rpm is None and ("load" in blob or "cpu" in blob or "gpu" in blob):
                    continue
                fans.append(
                    FanReading(
                        device_uid=uid,
                        device_name=name,
                        channel=ch_name,
                        label=label,
                        duty=duty,
                        rpm=rpm,
                        watts=watts,
                    )
                )
        return fans

    def _parse_temps(self, statuses: list[dict]) -> list[TempReading]:
        temps: list[TempReading] = []
        for dev in statuses:
            uid = dev.get("uid", "")
            name = self._device_names.get(uid, uid)
            latest = self._latest(dev)
            if not latest:
                continue
            for t in latest.get("temps", []):
                sensor = t.get("name", "?")
                value = t.get("temp")
                if value is None:
                    continue
                temps.append(
                    TempReading(
                        device_uid=uid,
                        device_name=name,
                        sensor=sensor,
                        label=self._temp_labels.get((uid, sensor), sensor),
                        temp=float(value),
                    )
                )
        return temps

    # -- the one call the UIs make ------------------------------------------

    def snapshot(self, include_modes: bool = True) -> CoolingSnapshot:
        """Full cooling snapshot: fans, temps, modes. Fails soft."""
        snap = CoolingSnapshot()
        try:
            self._refresh_metadata(self.devices())
            statuses = self.status()
            snap.fans = self._parse_fans(statuses)
            snap.temps = self._parse_temps(statuses)
            if include_modes:
                try:
                    snap.modes = self.modes()
                    snap.active_mode_uid = self.active_mode()
                except CCUnavailable as exc:
                    # Mode endpoints failing must not take the fans down with them.
                    snap.error = str(exc)
            snap.connected = True
        except CCUnavailable as exc:
            snap.connected = False
            snap.error = str(exc)
        return snap

    # -- convenience filters ---------------------------------------------------

    @staticmethod
    def coolant_temps(snap: CoolingSnapshot, device_match: str = "") -> list[TempReading]:
        """Temps from liquidctl devices (Octo etc.) — coolant + extra sensors.

        With ``device_match`` (case-insensitive substring of the device name,
        e.g. ``"octo"``) restrict to one device. The 3 Octo temp sensors show
        up here as individual entries.
        """
        needle = device_match.strip().lower()
        out = []
        for t in snap.temps:
            if needle and needle not in t.device_name.lower():
                continue
            out.append(t)
        return out

    @staticmethod
    def fans_from(snap: CoolingSnapshot, device_match: str = "") -> list[FanReading]:
        needle = device_match.strip().lower()
        return [
            f for f in snap.fans if not needle or needle in f.device_name.lower()
        ]
