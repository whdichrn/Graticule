"""
Interactive Map Canvas.
Provides high-performance graphics view with smooth zooming, panning,
exact map frame boundary detection, projection-aware inverse coordinate mapping,
and box-selection for sub-region extraction.
All labels, tooltips, and text are in English without emojis.
"""

from typing import Optional, Tuple, Any
import time
import math
import numpy as np
from pathlib import Path
import json
from PySide6 import QtCore, QtGui, QtWidgets


class InteractiveCanvas(QtWidgets.QGraphicsView):
    """Interactive viewport for viewing GMT generated maps."""

    # Signals
    cursor_coordinates = QtCore.Signal(float, float)  # (lon, lat) or (x, y)
    region_box_selected = QtCore.Signal(float, float, float, float)  # (w, e, s, n)
    selection_message = QtCore.Signal(str)
    zoom_level_changed = QtCore.Signal(float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.scene = QtWidgets.QGraphicsScene(self)
        self.setScene(self.scene)

        self.pixmap_item: Optional[QtWidgets.QGraphicsPixmapItem] = None
        self._current_pixmap: Optional[QtGui.QPixmap] = None

        # Geospatial & Projection metadata
        self.geo_region: Optional[Tuple[float, float, float, float]] = None
        self.projection: str = "Q16c"
        self.gmt_conf = ""
        self.map_dims_cm: Tuple[float, float] = (16.0, 8.0)
        self.engine: Optional[Any] = None
        self.map_frame_bbox: Tuple[int, int, int, int] = (0, 0, 1000, 600)

        # View settings & High-performance rendering optimizations
        self.setRenderHints(
            QtGui.QPainter.RenderHint.Antialiasing |
            QtGui.QPainter.RenderHint.SmoothPixmapTransform
        )
        self.setViewportUpdateMode(QtWidgets.QGraphicsView.ViewportUpdateMode.SmartViewportUpdate)
        self.setOptimizationFlag(QtWidgets.QGraphicsView.OptimizationFlag.DontAdjustForAntialiasing, True)
        self.setOptimizationFlag(QtWidgets.QGraphicsView.OptimizationFlag.DontSavePainterState, True)

        try:
            from PySide6 import QtOpenGLWidgets
            app = QtCore.QCoreApplication.instance()
            if app and app.platformName() != "offscreen":
                self.setViewport(QtOpenGLWidgets.QOpenGLWidget(self))
        except Exception:
            pass

        self.setDragMode(QtWidgets.QGraphicsView.DragMode.ScrollHandDrag)
        self.setTransformationAnchor(QtWidgets.QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.setResizeAnchor(QtWidgets.QGraphicsView.ViewportAnchor.AnchorViewCenter)
        self.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.setBackgroundBrush(QtGui.QBrush(QtGui.QColor(245, 247, 250)))

        # Throttling state for coordinate tracking
        self.setMouseTracking(True)
        self.viewport().setMouseTracking(True)
        self._hover_lookup = None
        self._last_coord_time = 0.0

        # Box selection mode
        self._box_select_mode = False
        self.is_box_selecting = False
        self.box_start_point = QtCore.QPointF()
        self.rubber_band = QtWidgets.QRubberBand(QtWidgets.QRubberBand.Shape.Rectangle, self)

    def set_box_select_mode(self, enabled: bool) -> None:
        """Enables or disables box selection mode."""
        self.is_box_selecting = False
        self.rubber_band.hide()
        self._box_select_mode = enabled
        if enabled:
            self.setDragMode(QtWidgets.QGraphicsView.DragMode.NoDrag)
            self.setCursor(QtCore.Qt.CursorShape.CrossCursor)
        else:
            self.setDragMode(QtWidgets.QGraphicsView.DragMode.ScrollHandDrag)
            self.setCursor(QtCore.Qt.CursorShape.OpenHandCursor)

    def is_box_select_mode(self) -> bool:
        return self._box_select_mode

    def set_map_image(self, image_path: str, geo_region: Optional[Tuple[float, float, float, float]] = None,
                      projection: str = "Q16c", map_dims_cm: Tuple[float, float] = (16.0, 8.0),
                      engine: Optional[Any] = None, hover_lookup=None, gmt_conf="") -> None:
        """Loads map image and detects exact map frame pixel rectangle."""
        pixmap = QtGui.QPixmap(image_path)
        if pixmap.isNull():
            return

        self._current_pixmap = pixmap
        self.geo_region = geo_region
        self.projection = projection
        self.gmt_conf = gmt_conf
        self.map_dims_cm = map_dims_cm
        self.engine = engine

        self._hover_lookup = hover_lookup
        self.is_box_selecting = False
        self.rubber_band.hide()
        try:
            metadata = json.loads(Path(image_path+".map.json").read_text())
            self.map_frame_bbox = tuple(metadata["bbox"])
        except (OSError, ValueError, KeyError):
            self.geo_region = None
            self.selection_message.emit("This image has no GMT map geometry. Render the plot to enable geographic selection.")

        self.scene.clear()
        self.pixmap_item = self.scene.addPixmap(pixmap)
        self.scene.setSceneRect(QtCore.QRectF(pixmap.rect()))

        self.fit_in_view()

    def fit_in_view(self) -> None:
        """Fits entire map within current viewport."""
        if self._current_pixmap and not self._current_pixmap.isNull():
            self.resetTransform()
            self.fitInView(QtCore.QRectF(self._current_pixmap.rect()), QtCore.Qt.AspectRatioMode.KeepAspectRatio)
            self.zoom_level_changed.emit(self.transform().m11())

    def reset_100_percent(self) -> None:
        """Resets zoom to 100% (1:1 pixel ratio)."""
        self.resetTransform()
        self.zoom_level_changed.emit(1.0)

    def wheelEvent(self, event: QtGui.QWheelEvent) -> None:
        """Smooth, high-performance zooming with mouse wheel and trackpad."""
        if not self._current_pixmap:
            return

        delta = event.angleDelta().y()
        if delta == 0:
            delta = event.pixelDelta().y() * 4
        if delta == 0:
            return

        # Proportional smooth exponential scaling
        # Standard mouse click delta is 120 -> 2^(120/600) ~ 1.15
        # Trackpad smooth delta is 2~10 -> 2^(5/600) ~ 1.006 (ultra-smooth)
        factor = math.pow(2.0, delta / 600.0)

        # Clamp zoom limits
        current_scale = self.transform().m11()
        if (factor > 1.0 and current_scale > 100.0) or (factor < 1.0 and current_scale < 0.02):
            return

        self.scale(factor, factor)
        self.zoom_level_changed.emit(self.transform().m11())
        event.accept()

    def mousePressEvent(self, event: QtGui.QMouseEvent) -> None:
        should_box_select = (
            self._box_select_mode or
            (event.modifiers() & QtCore.Qt.KeyboardModifier.ShiftModifier)
        )

        if event.button() == QtCore.Qt.MouseButton.LeftButton and should_box_select:
            if not self.geo_region or not self.engine:
                self.selection_message.emit("Render a plot before selecting a region.")
                event.accept()
                return
            self.is_box_selecting = True
            self.box_start_point = event.position().toPoint()
            self.rubber_band.setGeometry(QtCore.QRect(self.box_start_point, QtCore.QSize()))
            self.rubber_band.show()
            event.accept()
            return

        super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QtGui.QMouseEvent) -> None:
        if self.is_box_selecting:
            self.rubber_band.setGeometry(
                QtCore.QRect(self.box_start_point, event.position().toPoint()).normalized()
            )
            event.accept()
            return

        # Throttle coordinate lookup to avoid needless CPU load during fast movement
        now = time.perf_counter()
        if now - self._last_coord_time >= 0.05:  # cached lookup; no process launches on mouse movement
            self._last_coord_time = now
            if self.pixmap_item and self.geo_region and self.engine:
                scene_pos = self.mapToScene(event.position().toPoint())
                left, top, right, bottom = self.map_frame_bbox

                # Check if mouse is strictly within the map frame
                if left <= scene_pos.x() <= right and top <= scene_pos.y() <= bottom:
                    u = (scene_pos.x() - left) / max(1.0, right - left)
                    v = 1.0 - (scene_pos.y() - top) / max(1.0, bottom - top)
                    lon, lat = self._hover_coordinate(u, v)
                    if math.isfinite(lon) and math.isfinite(lat):
                        self.cursor_coordinates.emit(lon, lat)

        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QtGui.QMouseEvent) -> None:
        if self.is_box_selecting and event.button() == QtCore.Qt.MouseButton.LeftButton:
            self.is_box_selecting = False
            self.rubber_band.hide()

            rect_viewport = self.rubber_band.geometry()
            if rect_viewport.width() >= 15 and rect_viewport.height() >= 15 and self.geo_region and self.pixmap_item and self.engine:
                top_left_scene = self.mapToScene(rect_viewport.topLeft())
                bottom_right_scene = self.mapToScene(rect_viewport.bottomRight())

                left, top, right, bottom = self.map_frame_bbox
                p1_x = max(left, min(right, top_left_scene.x()))
                p1_y = max(top, min(bottom, top_left_scene.y()))
                p2_x = max(left, min(right, bottom_right_scene.x()))
                p2_y = max(top, min(bottom, bottom_right_scene.y()))

                frame_w = max(1.0, right - left)
                frame_h = max(1.0, bottom - top)

                u1 = (p1_x - left) / frame_w
                v1 = 1.0 - (p1_y - top) / frame_h
                u2 = (p2_x - left) / frame_w
                v2 = 1.0 - (p2_y - top) / frame_h

                region = self.selection_region(u1, v2, u2, v1)
                if region:
                    self.region_box_selected.emit(*region)
                else:
                    self.selection_message.emit("Selection contains no valid map area. Drag inside the projected map.")
            event.accept()
            return

        super().mouseReleaseEvent(event)

    def _hover_coordinate(self, u, v):
        if self._hover_lookup is None:
            return float("nan"), float("nan")
        lookup = self._hover_lookup
        x = u*(lookup.shape[1]-1); y = v*(lookup.shape[0]-1)
        i = min(int(x), lookup.shape[1]-2); j = min(int(y), lookup.shape[0]-2)
        corners = lookup[j:j+2, i:i+2]
        if not np.isfinite(corners).all() or np.ptp(corners[:, :, 0]) > 90:
            return float("nan"), float("nan")
        a, b = x-i, y-j
        return tuple((1-b)*((1-a)*corners[0, 0]+a*corners[0, 1])+b*((1-a)*corners[1, 0]+a*corners[1, 1]))

    def selection_region(self, u0, v0, u1, v1):
        """Sample the area, including its interior, so curved edges and poles count."""
        if not self.engine or not self.geo_region:
            return None
        try:
            return self.engine.compute_selection_region(
                u0, v0, u1, v1, self.geo_region, self.projection, self.map_dims_cm, self.gmt_conf
            )
        except (RuntimeError, ValueError) as exc:
            self.selection_message.emit(str(exc))
            return None
