"""hazyhud entry point.

  hazyhud                 Qt HUD (primary frontend)
  hazyhud --kiosk         Qt, frameless/always-on-top on the configured screen
  hazyhud --tui           Textual TUI (SSH/terminal fallback)
  hazyhud --init-config   write a commented starter config and exit
  hazyhud --config PATH   use a specific config file
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(prog="hazyhud", description="HazyHud v2 — system vitals HUD")
    parser.add_argument("--init-config", action="store_true",
                        help="write a starter config to ~/.config/hazyhud/config.yaml and exit")
    parser.add_argument("--config", type=Path, default=None, help="config file path")
    parser.add_argument("--kiosk", action="store_true",
                        help="frameless always-on-top mode for a dedicated display")
    parser.add_argument("--tui", action="store_true", help="run the terminal (Textual) frontend")
    args = parser.parse_args()

    if args.init_config:
        from .config import write_default_config, default_config_path

        config_path = args.config or default_config_path()
        defaults_path = config_path.parent / "config-defaults.yaml"
        result = write_default_config(args.config)
        if result == defaults_path:
            print(f"{config_path} already exists (not overwritten)")
        else:
            print(f"wrote {config_path}")
        print(f"wrote {defaults_path} (read-only reference)")
        return

    if args.tui:
        from .tui.app import HazyHudApp
        from .config import SharedConfig

        HazyHudApp(SharedConfig(args.config)).run()
        return

    from .qt.app import run

    sys.exit(run(args.config, kiosk=args.kiosk))


if __name__ == "__main__":
    main()
