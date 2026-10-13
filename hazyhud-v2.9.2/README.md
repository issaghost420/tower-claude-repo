# HazyHud

System vitals HUD for desktop Linux. Dark navy, cyan boxes, big readable numbers, color that shifts with your thermals, and a thin gradient bar on every box so you can read the state of your machine from across the room.

Two frontends share the same data layer — a Qt 6 HUD for your desktop (or a dedicated panel) and a Textual TUI for SSH sessions.

```
┌─────────────────────────────────────────────┐
│            Shared Data Layer                │
│  HazyHudCollector  (psutil, nvidia-smi,     │
│   RAPL, spd5118 — standalone, importable)   │
│  CoolerControlClient (REST :11987 — fans,   │
│   coolant, modes)                           │
│  SharedConfig (~/.config/hazyhud/config.     │
│   yaml — live-reloaded on save)             │
└──────┬──────────────────┬───────────────────┘
       ▼                  ▼
  Qt 6 HUD            Textual TUI
  (primary)           (--tui, for SSH)
```

## Install

```bash
pip install .            # Qt HUD
pip install ".[tui]"     # + TUI frontend
hazyhud --init-config    # writes a commented config to ~/.config/hazyhud/config.yaml
hazyhud                  # run
```

## Keys

| key | what it does |
|---|---|
| `q` | quit |
| `r` | reset min/max + averages |
| `m` | focus the mode switcher (↑↓ to browse, Enter to apply) |
| `h` | toggle the help bar |
| `e` | open config.yaml in your editor |
| `p` | cycle through layout presets (grid mode) |
| `o` | oops — reset tile positions (free mode) |
| drag | grid: swap boxes by title bar · free: move a tile by title bar |
| grip / edge | grid: resize from bottom-right corner · free: resize from any edge/corner |

**Drag to rearrange:** grab any box by its title bar and drop it on another box — they swap grid cells. Spans swap too, so a wide box and a narrow box trade cleanly without collisions.

**Resize by grip:** every box has a resize grip in the bottom-right corner (three diagonal ticks, cursor changes on hover). Drag it to set a pixel floor for that box — the grid flexes around it, nothing overlaps.

Both swaps and resize floors persist across restarts in QSettings, not in your config file — so your hand-written comments survive. To lock in an arrangement permanently, mirror it in `layout.widgets`; to lock in a size, set `min_width`/`min_height` for that widget in config — the file takes back control on save. To turn off dragging entirely: `layout.draggable: false`.

## Presets

The grid works like a spreadsheet — `row`/`col` coordinates, `colspan`/`rowspan` to stretch across cells. A preset is a named layout:

- **full** — 3 columns, everything (default)
- **compact** — 2 columns, stacked
- **cooling** — just the loop: coolant, power, fans, mode switcher
- **minimal** — CPU + GPUs, system + power

Set one with `layout.preset: compact`, or hit `p` to cycle through them live. You can write your own under `presets:` in the config — same shape.

Your `layout.widgets` entries override the preset. Set a widget to `null` to hide it. If your placement collides with a preset widget, yours wins — the preset one gets hidden with a warning in the help bar.

### Box sizing

Per-widget `min_width`/`min_height` set a pixel floor. `max_width`/`max_height` set a hard ceiling — boxes never grow past it. `hstretch`/`vstretch` control how greedy a box is with leftover window space.

### Tile mode

By default boxes stretch to fill the window. For compact tiles (Home Assistant style):

```yaml
layout:
  fill: false
  spread_rows: false
  box_padding: { x: 10, y: 6 }
  row_spacing: 0
```

To shrink boxes below their content (clip/overlap, like a normal window):

```yaml
layout:
  allow_squash: true
  min_box: { width: 40, height: 30 }
```

## Free mode (drag canvas)

Grid mode arranges tiles in a spreadsheet. Free mode is a table you set: tiles go anywhere in the window, and they stay where you put them.

```yaml
layout:
  mode: free
  snap_to_edges: true    # tiles magnet to window + each other's edges
  snap_to_grid: false    # optional: also quantize to a pixel grid
  grid_size: 8
  allow_overlap: false   # false = a dropped tile slides to the nearest free
                         # spot instead of covering another
```

Drag a tile by its **top strip** (title-bar height) to move it. Drag the fat **bottom-right corner** to resize it, both directions at once. Positions and sizes autosave per tile to `last-layout.yaml` (next to `config.yaml`) on every move and resize — a real file you can read, diff, or delete — so your commented config stays clean. Presets and the `layout.widgets` grid don't apply in free mode — the first time you switch, tiles seed from wherever the grid would've placed them, spread across the whole window, and you sculpt from there.

Snapping is weak and forgiving — get close and tiles click to the window edges or to each other. A wide tile clears the tallest neighbor it spans, so staggered layouts fall out naturally. If things ever get messy, press **`o`** (oops) to reset all tile positions.

By default the next launch restores your tile arrangement (`launch.restore_last_layout: true`). Set it to `false` to always start fresh from a preset's grid, optionally picked with `launch.launch_layout` (ignored while restore is on).

Tiles can shrink to a sliver when `layout.allow_squash: true`; with it off, a tile won't resize smaller than what its content needs to stay readable.

**Wayland note:** on Wayland (KDE's default), apps can't position their own windows — the compositor owns placement, so `kiosk.screen` and hardcoded positions are ignored (size still applies). To pin HazyHud to a screen on KDE Wayland, use a Window Rule matching class `hazyhud`. On X11 it works directly.

## The config file

Everything visual lives in `~/.config/hazyhud/config.yaml` and reloads live on save — no restart needed.

The generated config (`hazyhud --init-config`) is heavily commented and covers everything: layout, fonts, colors, bars, thresholds, kiosk mode, CoolerControl auth, and more. Numbers are clamped to sane ranges so a typo looks ugly at worst, never crashes.

## Kiosk mode

For a dedicated display — frameless, always on top, no taskbar entry:

```yaml
kiosk:
  enabled: true
  screen: 0
  frameless: true
  always_on_top: true
  skip_taskbar: true
```

Or just `hazyhud --kiosk`.

On KDE Plasma, to pin it across virtual desktops: **Window Rules → match class `hazyhud` → Desktop: All Desktops**. Autostart via **System Settings → Autostart → Add Application**.

## CoolerControl integration

Fan speeds, coolant temps (Octo sensors), flow, and cooling modes come from the CoolerControl daemon on `localhost:11987`. If Access Protection is on, create a token in the CC UI — read-only is enough to monitor, write access is needed for mode switching. Set it in `coolercontrol.token`.

Mode switching is the only write HazyHud performs. Fan curves and profiles stay in CoolerControl where they belong.

## Dev preview

Render the HUD with fake data to a PNG — no hardware or running daemon needed:

```bash
QT_QPA_PLATFORM=offscreen python3 tools/render_preview.py out.png 1920 515
QT_QPA_PLATFORM=offscreen python3 tools/render_preview.py out.png 1600 640 --config /path/to/config.yaml
```

## Notes

- CPU power reads from RAPL (`/sys/class/powercap/intel-rapl:0/energy_uj`). The driver is called `intel-rapl` but works on AMD Ryzen too. Probed at startup — if it's not there, you get N/A instead of a crash.
- GPU averages are time-weighted so tick jitter from slow nvidia-smi queries can't skew them. Every GPU is sampled unconditionally on every tick.
- TUI: `hazyhud --tui`. Font settings in the config only affect the Qt HUD — the TUI uses whatever your terminal is set to.

## License

MIT
