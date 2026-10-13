"""FreeCanvas — the free-placement layout surface (layout.mode: free).

Grid mode arranges tiles in a spreadsheet. Free mode is a table you set:
tiles live at absolute positions inside the window, you drag them by their
title bar, resize them from any edge or corner, and they stay put. The
window sets the borders; you arrange the plates inside it.

Design intent (from the user):
- Wide-open canvas, weak/forgiving snapping — never fights the sculptor.
- Snap targets: window edges + the edges of other tiles ("bump together").
- A wide tile can't tuck under just one of the tiles it spans — it clears
  the *tallest* neighbor it overlaps horizontally, so staggered layouts fall
  out naturally without any column bookkeeping.
- Overlap is prevented by snapping to the nearest free spot on drop, not by
  shoving other tiles around (no whack-a-mole). Unless allow_overlap: true.

Nothing here knows about metrics — tiles are opaque QWidgets the window
builds and hands over. Geometry persists per-tile in ``last-layout.yaml``
next to config.yaml (autosaved on every move/resize), so the commented
config.yaml stays clean and the saved layout is a file you can see, diff,
or delete. Pre-2.9.2 geometry in QSettings is migrated on first save.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

import yaml
from PySide6.QtCore import QPoint, QRect, QSettings, Qt, Signal
from PySide6.QtWidgets import QSizePolicy, QWidget

from ..config import SharedConfig

#: how close (px) an edge must be to a snap line before it clicks
SNAP_PROXIMITY = 12
#: below this the canvas hasn't been given real geometry by the compositor
#: yet, and anything we compute from its size is garbage. Nothing is clamped,
#: seeded or saved until both axes clear this.
MIN_LIVE = 80
#: smallest a tile can be dragged to on the canvas
MIN_TILE_W = 60
MIN_TILE_H = 40
#: bottom-right resize corner hit zone, px (fat, like a window button)
GRIP_ZONE = 28
#: height of the top strip that acts as the move handle, px
TITLE_STRIP = 40


class FreeTile(QWidget):
    """A thin wrapper the canvas positions absolutely. It holds the real
    vitals box as its only child. Move = drag anywhere in the top strip
    (title-bar height). Resize = drag the fat bottom-right corner, both axes
    at once — the corner grip people expect."""

    #: emitted (name) whenever this tile's geometry changes and should persist
    geometryCommitted = Signal(str)

    def __init__(self, name: str, inner: QWidget, canvas: "FreeCanvas") -> None:
        super().__init__(canvas)
        self.name = name
        self.canvas = canvas
        self._inner = inner
        inner.setParent(self)
        inner.move(0, 0)

        self._mode: Optional[str] = None   # "move" | "resize" | None
        self._press_global = QPoint()
        self._start_geo = QRect()
        self._grid_spec: Optional[dict] = None  # seed hint for first launch
        #: the geometry this tile *wants*. Clamping to a too-small canvas is
        #: lossy — it crushes a 700px tile to 200px and there's no way back —
        #: so the wish is kept separate and every clamp is recomputed from it.
        #: Updated only by the user (on drop) or by a fresh seed.
        self._want: Optional[QRect] = None

        self.setMouseTracking(True)
        inner.setMouseTracking(True)
        # Forward mouse events from the inner box AND its child labels up to
        # the tile, so the whole top strip and corner are grabbable no matter
        # what widget sits under the cursor.
        inner.installEventFilter(self)
        for child in inner.findChildren(QWidget):
            child.setMouseTracking(True)
            child.installEventFilter(self)

    def resizeEvent(self, event) -> None:  # noqa: N802
        self._inner.resize(self.size())

    # -- hit zones -----------------------------------------------------------

    def _in_grip(self, pos: QPoint) -> bool:
        return (
            pos.x() >= self.width() - GRIP_ZONE
            and pos.y() >= self.height() - GRIP_ZONE
        )

    def _in_title(self, pos: QPoint) -> bool:
        return pos.y() <= TITLE_STRIP and not self._in_grip(pos)

    def _zone(self, pos: QPoint) -> str:
        if self._in_grip(pos):
            return "resize"
        if self._in_title(pos):
            return "move"
        return ""

    # -- unified mouse handling (tile + forwarded child events) --------------

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        et = event.type()
        if et in (
            event.Type.MouseButtonPress,
            event.Type.MouseMove,
            event.Type.MouseButtonRelease,
        ):
            pos = self.mapFromGlobal(event.globalPosition().toPoint())
            if self._handle_mouse(et, event, pos):
                return True
        return super().eventFilter(obj, event)

    def _handle_mouse(self, et, event, pos: QPoint) -> bool:
        if et == event.Type.MouseButtonPress and event.button() == Qt.LeftButton:
            zone = self._zone(pos)
            if not zone:
                return False
            self._mode = zone
            self._press_global = event.globalPosition().toPoint()
            self._start_geo = self.geometry()
            self.raise_()
            return True
        if et == event.Type.MouseMove and self._mode:
            delta = event.globalPosition().toPoint() - self._press_global
            if self._mode == "move":
                self.canvas.tile_moving(self, self._start_geo.translated(delta))
            else:  # resize from bottom-right, both axes at once
                min_w, min_h = self.canvas.tile_floor(self)
                geo = QRect(self._start_geo)
                geo.setWidth(max(min_w, self._start_geo.width() + delta.x()))
                geo.setHeight(max(min_h, self._start_geo.height() + delta.y()))
                self.canvas.tile_resizing(self, geo)
            return True
        if et == event.Type.MouseButtonRelease and self._mode:
            self._mode = None
            self.canvas.tile_dropped(self)
            return True
        return False

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if self._handle_mouse(event.type(), event, event.position().toPoint()):
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        pos = event.position().toPoint()
        if self._mode:
            self._handle_mouse(event.type(), event, pos)
            event.accept()
            return
        zone = self._zone(pos)
        if zone == "resize":
            self.setCursor(Qt.SizeFDiagCursor)
        elif zone == "move":
            self.setCursor(Qt.SizeAllCursor)
        else:
            self.unsetCursor()
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        if self._handle_mouse(event.type(), event, event.position().toPoint()):
            event.accept()
            return
        super().mouseReleaseEvent(event)


class FreeCanvas(QWidget):
    """Holds FreeTiles at absolute positions and does the snap math."""

    def __init__(self, cfg: SharedConfig, settings: QSettings, parent=None) -> None:  # type: ignore[name-defined]
        super().__init__(parent)
        self.setObjectName("canvas")
        self.cfg = cfg
        self._settings = settings
        self._tiles: dict[str, FreeTile] = {}
        # Saved tile rects — the ownership view. launch.restore_last_layout is
        # a LAUNCH-time switch (sampled once here): when off, geometry from
        # previous sessions is ignored and every tile re-seeds from the
        # preset, while drops made THIS session still stick (and still
        # autosave, so flipping the option on restores the latest state).
        if self.cfg.launch_restore_last_layout:
            self._saved: dict[str, list[int]] = self._read_saved_raw()
        else:
            self._saved = {}
        #: set whenever the tile set or the canvas size changes; cleared by
        #: _apply_layout() once the canvas is real-sized. Layout is never
        #: attempted before that, so there is no seed-timing race to lose.
        self._needs_layout = True
        # Without a layout a QWidget reports a tiny sizeHint and collapses in
        # the root grid — force it to eat all available space so the canvas
        # is the full window minus the help bar.
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(0, 0)

    # -- population ----------------------------------------------------------

    def clear_tiles(self) -> None:
        for tile in self._tiles.values():
            tile.setParent(None)
            tile.deleteLater()
        self._tiles.clear()
        self._needs_layout = True

    def add_tile(self, name: str, inner: QWidget, seed: QRect,
                 grid_spec: Optional[dict] = None) -> FreeTile:
        """Register a tile. Nothing is positioned here — at build time the
        canvas has no real size yet, and clamping against a fake size is what
        used to crush every saved layout into a corner. The tile records what
        it wants; _apply_layout() places it once the geometry is real."""
        tile = FreeTile(name, inner, self)
        tile._grid_spec = grid_spec
        saved = self._load_geometry(name)
        tile._want = QRect(saved) if saved is not None else QRect(seed)
        tile.setGeometry(tile._want)  # provisional; corrected on first layout
        tile.show()
        self._tiles[name] = tile
        self._needs_layout = True
        # a config hot-reload rebuilds tiles without any resize, so make sure
        # a paint is queued — that's what runs the pending layout
        self.update()
        return tile

    def reseed_now(self) -> None:
        """Force a fresh layout pass on the next paint."""
        self._needs_layout = True
        self._apply_layout()

    # -- layout --------------------------------------------------------------

    def _is_live(self) -> bool:
        """True once the compositor has given us real geometry. Everything
        that reads self.width()/height() is gated on this."""
        return self.width() >= MIN_LIVE and self.height() >= MIN_LIVE

    def _apply_layout(self) -> None:
        """Place every tile against the canvas's real current size.

        Two classes of tile:
        - **owned** — the user has dragged or resized it, so there's saved
          geometry. It keeps its spot; we only clamp it back inside the
          window, and always recompute that clamp from `_want` so shrinking
          the window and growing it again restores the original size.
        - **unowned** — never touched. It re-flows from its grid spec on
          every resize, so an untouched HUD always fills the window no matter
          what size it opens at. The moment you drag it, it's yours and it
          stops moving.

        This is why there is no seed timing any more: layout is a function of
        (canvas size, saved geometry), recomputed whenever either changes,
        not a one-shot that has to fire at exactly the right moment.
        """
        if not self._is_live() or not self._tiles:
            return
        self._needs_layout = False
        cw, ch = self.width(), self.height()
        saved = self._load_all()
        margin = self.cfg.layout_margin
        spacing = self.cfg.layout_spacing

        owned = [t for n, t in self._tiles.items() if n in saved]
        unowned = [t for n, t in self._tiles.items()
                   if n not in saved and t._grid_spec]
        stray = [t for n, t in self._tiles.items()
                 if n not in saved and not t._grid_spec]

        if unowned:
            # the reflow grid is the FULL placement grid, not just the tiles
            # being reflowed — otherwise the leftovers stretch across columns
            # that owned tiles are still sitting in
            specs = [t._grid_spec for t in self._tiles.values() if t._grid_spec]
            columns = max((s["col"] + s["colspan"] for s in specs), default=1)
            max_row = max((s["row"] + s["rowspan"] for s in specs), default=1)
            col_w = (cw - margin * 2) / max(columns, 1)
            row_h = (ch - margin * 2) / max(max_row, 1)
            for tile in unowned:
                spec = tile._grid_spec
                tile._want = QRect(
                    int(margin + spec["col"] * col_w),
                    int(margin + spec["row"] * row_h),
                    max(MIN_TILE_W, int(spec["colspan"] * col_w) - spacing),
                    max(MIN_TILE_H, int(spec["rowspan"] * row_h) - spacing),
                )

        # Owned tiles keep their spot — the user put them there. They are only
        # ever clamped back inside the window, never shoved by the overlap
        # resolver: shoving during layout is how a 2px brush with a reflowed
        # tile used to permanently drift a saved position, and how a small
        # window used to pile every owned tile into one corner (they were
        # clamped into each other, then shoved around). They may overlap
        # while the window is too small for the saved arrangement; growing
        # the window back restores them exactly, because the clamp is always
        # recomputed from _want.
        for tile in owned + stray:
            want = tile._want if tile._want is not None else tile.geometry()
            tile.setGeometry(self._clamp_to_canvas(want))

        # Unowned tiles land on their reflow cell. Place them ALL first, then
        # resolve — a resolve that runs while later tiles still hold their
        # previous-pass geometry tests against ghosts and shoves tiles away
        # from perfectly good cells. Owned tiles are already at their clamped
        # spots, so the unowned one always slides aside, never the other way
        # round.
        for tile in unowned:
            tile.setGeometry(self._clamp_to_canvas(tile._want))
        if not self.cfg.free_allow_overlap:
            for tile in unowned:
                resolved = self._resolve_overlap(tile, tile.geometry())
                if resolved is not None:
                    tile.setGeometry(resolved)
                # None: nowhere clean — keep the reflow cell

    def _has_saved(self, name: str) -> bool:
        return name in self._load_all()

    def tiles(self) -> list[FreeTile]:
        return list(self._tiles.values())

    # -- persistence ---------------------------------------------------------

    def _geo_key(self) -> str:
        """Legacy QSettings key — the pre-2.9.2 geometry store, kept only as
        a migration source."""
        return "free_geometry"

    def _layout_path(self) -> Path:
        """The autosaved layout file, next to config.yaml."""
        return self.cfg.path.parent / "last-layout.yaml"

    def _read_saved_raw(self) -> dict[str, list[int]]:
        """Everything in the autosave file, WITHOUT the restore_last_layout
        gate — saves merge against this so writing one tile never drops the
        others, even while restore is off."""
        try:
            data = yaml.safe_load(self._layout_path().read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError):
            data = {}
        tiles = data.get("tiles") if isinstance(data, dict) else None
        out: dict[str, list[int]] = {}
        if isinstance(tiles, dict):
            for k, v in tiles.items():
                try:
                    out[str(k)] = [int(x) for x in v]
                except (TypeError, ValueError):
                    continue
        if out:
            return out
        # legacy fallback: pre-2.9.2 geometry lived in QSettings. Read-only —
        # the next save writes last-layout.yaml and the migration is done.
        try:
            raw = self._settings.value(self._geo_key(), "")
            data = json.loads(raw) if raw else {}
            return {str(k): [int(x) for x in v] for k, v in data.items()}
        except (ValueError, TypeError, IndexError):
            return {}

    def _load_all(self) -> dict[str, list[int]]:
        return self._saved

    def _load_geometry(self, name: str) -> Optional[QRect]:
        g = self._saved.get(name)
        if g and len(g) == 4:
            return QRect(g[0], g[1], g[2], g[3])
        return None

    def _save_geometry(self, name: str) -> None:
        tile = self._tiles.get(name)
        if tile is None or not self._is_live():
            return  # never write coordinates measured against a fake size
        allg = self._read_saved_raw()
        g = tile.geometry()
        allg[name] = [g.x(), g.y(), g.width(), g.height()]
        self._saved[name] = allg[name]
        payload = {
            "window": [self.width(), self.height()],
            "tiles": allg,
        }
        try:
            self._layout_path().write_text(
                "# hazyhud free-mode layout — autosaved on every tile move/resize.\n"
                "# Delete this file (or press 'o') to re-seed tiles from the preset.\n"
                "# Honored at launch when launch.restore_last_layout is true.\n"
                + yaml.safe_dump(payload, sort_keys=True),
                encoding="utf-8",
            )
        except OSError:
            pass  # read-only config dir — keep running; layout just won't persist

    def clear_saved_geometry(self) -> None:
        """The 'o' (oops) reset — wipe saved positions so tiles re-seed."""
        self._saved = {}
        self._settings.remove(self._geo_key())
        try:
            self._layout_path().unlink()
        except OSError:
            pass  # FileNotFoundError is an OSError too — nothing to wipe

    def tile_floor(self, tile: FreeTile) -> tuple[int, int]:
        """Smallest size a tile may be resized to. With layout.allow_squash
        on, that's the tiny canvas floor — clipping your own labels is the
        point. With it OFF the floor is the box's content minimum, so a tile
        can never be dragged smaller than what it has to show. (Free mode
        used to ignore allow_squash entirely and always squash.)"""
        if self.cfg.layout_allow_squash:
            return MIN_TILE_W, MIN_TILE_H
        hint = tile._inner.minimumSizeHint()
        return max(MIN_TILE_W, hint.width()), max(MIN_TILE_H, hint.height())

    # -- snap math -----------------------------------------------------------

    def _clamp_to_canvas(self, geo: QRect) -> QRect:
        """Keep a tile inside the window bounds where it can, but never force
        it smaller than the min tile size."""
        cw, ch = self.width(), self.height()
        g = QRect(geo)
        if cw > 0 and g.width() > cw:
            g.setWidth(cw)
        if ch > 0 and g.height() > ch:
            g.setHeight(ch)
        if cw > 0:
            g.moveLeft(max(0, min(g.left(), cw - g.width())))
        if ch > 0:
            g.moveTop(max(0, min(g.top(), ch - g.height())))
        return g

    def _snap_lines(self, exclude: FreeTile):
        """Vertical and horizontal snap lines: window edges + every other
        tile's edges."""
        vlines = {0, self.width()}
        hlines = {0, self.height()}
        for t in self._tiles.values():
            if t is exclude:
                continue
            g = t.geometry()
            vlines.add(g.left())
            vlines.add(g.right() + 1)
            hlines.add(g.top())
            hlines.add(g.bottom() + 1)
        return sorted(vlines), sorted(hlines)

    def _snap_geo(self, tile: FreeTile, geo: QRect, moving: bool) -> QRect:
        """Apply weak edge-magnetism. When moving, snap position; when
        resizing, snap the grabbed edges. Grid snap (if on) is applied first
        as a coarse quantize, edge snap second so it wins when close."""
        g = QRect(geo)

        if self.cfg.free_snap_to_grid:
            step = max(1, self.cfg.free_grid_size)
            g.moveLeft(round(g.left() / step) * step)
            g.moveTop(round(g.top() / step) * step)
            if not moving:
                min_w, min_h = self.tile_floor(tile)
                g.setWidth(max(min_w, round(g.width() / step) * step))
                g.setHeight(max(min_h, round(g.height() / step) * step))

        if self.cfg.free_snap_to_edges:
            vlines, hlines = self._snap_lines(tile)
            # Horizontal position: snap whichever of left/right edge is closest
            # to a vertical line — closest wins so edges don't fight.
            left_snap = self._nearest(g.left(), vlines)
            right_snap = self._nearest(g.right() + 1, vlines)
            left_d = abs(left_snap - g.left()) if left_snap is not None else 10**9
            right_d = abs(right_snap - (g.right() + 1)) if right_snap is not None else 10**9
            if left_d <= right_d and left_snap is not None:
                g.moveLeft(left_snap)
            elif right_snap is not None:
                g.moveLeft(right_snap - g.width())
            # Vertical position: same, top vs bottom edge, closest wins.
            top_snap = self._nearest(g.top(), hlines)
            bot_snap = self._nearest(g.bottom() + 1, hlines)
            top_d = abs(top_snap - g.top()) if top_snap is not None else 10**9
            bot_d = abs(bot_snap - (g.bottom() + 1)) if bot_snap is not None else 10**9
            if top_d <= bot_d and top_snap is not None:
                g.moveTop(top_snap)
            elif bot_snap is not None:
                g.moveTop(bot_snap - g.height())

        return g

    @staticmethod
    def _nearest(value: int, lines) -> Optional[int]:
        best = None
        best_d = SNAP_PROXIMITY + 1
        for ln in lines:
            d = abs(value - ln)
            if d < best_d:
                best_d = d
                best = ln
        return best if best_d <= SNAP_PROXIMITY else None

    def _overlaps(self, tile: FreeTile, geo: QRect) -> list[QRect]:
        return [
            t.geometry() for t in self._tiles.values()
            if t is not tile and t.geometry().intersects(geo)
        ]

    def _resolve_overlap(self, tile: FreeTile, geo: QRect) -> Optional[QRect]:
        """No auto-reflow: if the dropped rect overlaps, slide it to the
        nearest spot that clears everything. Wide tiles naturally clear the
        tallest neighbor they span because we test against all tiles at once
        and keep the smallest move. Returns None when there is nowhere clean —
        the caller decides what "stay put" means for it."""
        if not self._overlaps(tile, geo):
            return geo

        origin = geo.topLeft()
        # Build candidate escapes off every tile we currently hit: just past
        # each of its four edges. Re-tested against ALL tiles, so a candidate
        # that clears one neighbor but lands on another is rejected.
        seen: set[tuple[int, int]] = set()
        candidates: list[QRect] = []
        # a few passes so a push past one tile can then be pushed past the next
        frontier = [geo]
        for _ in range(4):
            next_frontier: list[QRect] = []
            for rect in frontier:
                for hit in self._overlaps(tile, rect):
                    for cand in (
                        QRect(rect.x(), hit.bottom() + 1, rect.width(), rect.height()),
                        QRect(rect.x(), hit.top() - rect.height(), rect.width(), rect.height()),
                        QRect(hit.right() + 1, rect.y(), rect.width(), rect.height()),
                        QRect(hit.left() - rect.width(), rect.y(), rect.width(), rect.height()),
                    ):
                        cand = self._clamp_to_canvas(cand)
                        key = (cand.x(), cand.y())
                        if key in seen:
                            continue
                        seen.add(key)
                        if not self._overlaps(tile, cand):
                            candidates.append(cand)
                        else:
                            next_frontier.append(cand)
            if candidates:
                break
            frontier = next_frontier
            if not frontier:
                break

        if candidates:
            candidates.sort(key=lambda r: (r.topLeft() - origin).manhattanLength())
            return candidates[0]
        return None  # nowhere clean

    # -- interaction callbacks from FreeTile ---------------------------------

    def tile_moving(self, tile: FreeTile, geo: QRect) -> None:
        snapped = self._snap_geo(tile, self._clamp_to_canvas(geo), moving=True)
        tile.setGeometry(snapped)

    def tile_resizing(self, tile: FreeTile, geo: QRect) -> None:
        # floor here too, not just in the drag handler — anything that feeds
        # a resize rect through here respects the squash setting
        min_w, min_h = self.tile_floor(tile)
        g = QRect(geo)
        g.setWidth(max(min_w, g.width()))
        g.setHeight(max(min_h, g.height()))
        snapped = self._snap_geo(tile, g, moving=False)
        tile.setGeometry(self._clamp_to_canvas(snapped))

    def tile_dropped(self, tile: FreeTile) -> None:
        geo = tile.geometry()
        if not self.cfg.free_allow_overlap:
            resolved = self._resolve_overlap(tile, geo)
            if resolved is not None:
                geo = resolved
                tile.setGeometry(geo)
            # None: nowhere clean — the tile stays where it was dropped
        # a deliberate gesture — this is now the tile's wish, and it's owned
        tile._want = QRect(tile.geometry())
        self._save_geometry(tile.name)

    # -- geometry hooks ------------------------------------------------------

    def resizeEvent(self, event) -> None:  # noqa: N802
        self._needs_layout = True
        self._apply_layout()
        super().resizeEvent(event)

    def showEvent(self, event) -> None:  # noqa: N802
        self._needs_layout = True
        super().showEvent(event)

    def paintEvent(self, event) -> None:  # noqa: N802
        # The one moment geometry is guaranteed real: the compositor has
        # configured the surface and Qt is about to draw it. Any pending
        # layout lands here, whatever order show/resize arrived in.
        if self._needs_layout:
            self._apply_layout()
        super().paintEvent(event)
