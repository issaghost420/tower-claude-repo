"""HazyHud v2 — shared data layer + Qt HUD + Textual TUI fallback."""

__version__ = "2.9.2"

from .collector import HazyHudCollector
from .cc_client import CoolerControlClient, CCUnavailable, CCAuthError
from .config import SharedConfig

__all__ = [
    "HazyHudCollector",
    "CoolerControlClient",
    "CCUnavailable",
    "CCAuthError",
    "SharedConfig",
    "__version__",
]
