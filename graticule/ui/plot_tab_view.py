"""
Plot Tab View.
Encapsulates an InteractiveCanvas with its own toolbar, title,
and independent PlotConfig state.
All labels, tooltips, and text are in English without emojis.
"""

from dataclasses import replace
from typing import Optional, Tuple, Any
from PySide6 import QtCore, QtGui, QtWidgets
from ..backend.gmt_engine import PlotConfig, GMTEngine
from .interactive_canvas import InteractiveCanvas


class RegionDialog(QtWidgets.QDialog):
    """Dialog to manually specify map bounds."""
    def __init__(self, region: Tuple[float, float, float, float], parent=None):
        super().__init__(parent)
        self.setWindowTitle("Specify Region Coordinates")
        self.resize(280, 180)

        layout = QtWidgets.QGridLayout(self)

        self.spin_w = QtWidgets.QDoubleSpinBox()
        self.spin_e = QtWidgets.QDoubleSpinBox()
        self.spin_s = QtWidgets.QDoubleSpinBox()
        self.spin_n = QtWidgets.QDoubleSpinBox()

        for s in (self.spin_w, self.spin_e, self.spin_s, self.spin_n):
            s.setRange(-1e6, 1e6)
            s.setDecimals(4)

        self.spin_w.setValue(region[0])
        self.spin_e.setValue(region[1])
        self.spin_s.setValue(region[2])
        self.spin_n.setValue(region[3])

        layout.addWidget(QtWidgets.QLabel("North:"), 0, 1, QtCore.Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.spin_n, 1, 1)
        layout.addWidget(QtWidgets.QLabel("West:"), 2, 0)
        layout.addWidget(self.spin_w, 3, 0)
        layout.addWidget(QtWidgets.QLabel("East:"), 2, 2)
        layout.addWidget(self.spin_e, 3, 2)
        layout.addWidget(QtWidgets.QLabel("South:"), 4, 1, QtCore.Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.spin_s, 5, 1)

        btn_box = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.StandardButton.Ok | QtWidgets.QDialogButtonBox.StandardButton.Cancel
        )
        btn_box.accepted.connect(self.accept)
        btn_box.rejected.connect(self.reject)
        layout.addWidget(btn_box, 6, 0, 1, 3)

    def get_region(self) -> Tuple[float, float, float, float]:
        return (
            self.spin_w.value(),
            self.spin_e.value(),
            self.spin_s.value(),
            self.spin_n.value()
        )


class PlotTabView(QtWidgets.QWidget):
    """Container widget for a single plot tab."""

    selection_message = QtCore.Signal(str)
    cursor_coordinates = QtCore.Signal(float, float)
    spawn_subregion_tab = QtCore.Signal(object)  # Emits new PlotConfig for a subregion
    request_re_render = QtCore.Signal(object)    # Emits current PlotConfig

    def __init__(self, title: str, config: PlotConfig, parent=None):
        super().__init__(parent)
        self.tab_title = title
        self.config = config
        self.display_config = config
        self.latest_request = 0
        self.image_path: Optional[str] = None
        self.engine: Optional[GMTEngine] = None

        self._setup_ui()

    def _setup_ui(self) -> None:
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(2)

        # Mini Toolbar
        self.bar = QtWidgets.QToolBar()
        self.bar.setIconSize(QtCore.QSize(16, 16))
        self.bar.setStyleSheet("QToolBar { border-bottom: 1px solid #dcdcdc; background: #fafafa; padding: 2px; }")

        # Mode buttons (Pan vs Select Mode)
        self.act_pan = self.bar.addAction("Pan Mode")
        self.act_pan.setCheckable(True)
        self.act_pan.setChecked(True)
        self.act_pan.setToolTip("Drag with left mouse button to pan the map view")

        self.act_box = self.bar.addAction("Select Mode")
        self.act_box.setCheckable(True)
        self.act_box.setToolTip("Click and drag a bounding box on the map to inspect and open that region in a new tab")

        mode_group = QtGui.QActionGroup(self)
        mode_group.addAction(self.act_pan)
        mode_group.addAction(self.act_box)
        mode_group.setExclusive(True)

        self.act_pan.triggered.connect(lambda: self.canvas.set_box_select_mode(False))
        self.act_box.triggered.connect(lambda: self.canvas.set_box_select_mode(True))

        self.bar.addSeparator()

        # Polar Selection Menu
        polar_btn = QtWidgets.QToolButton()
        polar_btn.setText("Polar Select")
        polar_btn.setPopupMode(QtWidgets.QToolButton.ToolButtonPopupMode.InstantPopup)
        polar_btn.setToolTip("Select Arctic or Antarctic polar regions with specialized polar stereographic projections")
        polar_menu = QtWidgets.QMenu(polar_btn)

        act_arctic = polar_menu.addAction("Arctic Ocean (60N to 90N, -JS0/90)")
        act_arctic.triggered.connect(lambda: self._spawn_polar(0.0, 360.0, 60.0, 90.0, "S0/90/15c", "Arctic [60N-90N]"))

        act_high_arctic = polar_menu.addAction("High Arctic (75N to 90N, -JS0/90)")
        act_high_arctic.triggered.connect(lambda: self._spawn_polar(0.0, 360.0, 75.0, 90.0, "S0/90/15c", "High Arctic [75N-90N]"))

        polar_menu.addSeparator()

        act_antarctic = polar_menu.addAction("Antarctic / Southern Ocean (60S to 90S, -JS0/-90)")
        act_antarctic.triggered.connect(lambda: self._spawn_polar(0.0, 360.0, -90.0, -60.0, "S0/-90/15c", "Antarctica [60S-90S]"))

        act_high_antarctic = polar_menu.addAction("High Antarctic (75S to 90S, -JS0/-90)")
        act_high_antarctic.triggered.connect(lambda: self._spawn_polar(0.0, 360.0, -90.0, -75.0, "S0/-90/15c", "High Antarctic [75S-90S]"))

        polar_btn.setMenu(polar_menu)
        self.bar.addWidget(polar_btn)

        self.bar.addSeparator()

        act_region = self.bar.addAction("Set Region...")
        act_region.setToolTip("Manually input region bounds and zoom to a new tab")
        act_region.triggered.connect(self._open_region_dialog)

        act_fit = self.bar.addAction("Fit Window")
        act_fit.setToolTip("Fit image to current viewport")
        act_fit.triggered.connect(lambda: self.canvas.fit_in_view())

        act_100 = self.bar.addAction("1:1 Scale")
        act_100.setToolTip("Reset zoom to 100% pixel scale")
        act_100.triggered.connect(lambda: self.canvas.reset_100_percent())

        self.bar.addSeparator()

        # Scope info label
        self.lbl_info = QtWidgets.QLabel(self._format_region_info())
        self.lbl_info.setStyleSheet("color: #555; font-size: 11px; margin-left: 8px;")
        self.bar.addWidget(self.lbl_info)

        layout.addWidget(self.bar)

        # Canvas
        self.canvas = InteractiveCanvas()
        self.canvas.cursor_coordinates.connect(self.cursor_coordinates.emit)
        self.canvas.region_box_selected.connect(self._on_box_selected)
        self.canvas.selection_message.connect(self.selection_message.emit)
        layout.addWidget(self.canvas)

    def _format_region_info(self) -> str:
        if self.config.region:
            w, e, s, n = self.config.region
            return f"Region: [{w:.2f} to {e:.2f}, {s:.2f} to {n:.2f}]"
        return "Region: [Full Grid]"

    def set_map_image(self, image_path: str, config: PlotConfig, engine: Optional[GMTEngine] = None, hover_lookup=None) -> None:
        """Updates canvas with newly generated image and stores the config."""
        self.image_path = image_path
        self.config = config
        self.display_config = config
        self.engine = engine
        self.lbl_info.setText(self._format_region_info())

        map_dims_cm = (16.0, 8.0)
        if engine:
            map_dims_cm = engine.get_map_dimensions_cm(config.region, config.projection, config.gmt_conf)

        self.canvas.set_map_image(
            image_path=image_path,
            geo_region=config.region,
            projection=config.projection,
            map_dims_cm=map_dims_cm,
            engine=engine, hover_lookup=hover_lookup, gmt_conf=config.gmt_conf
        )

    def _spawn_polar(self, w: float, e: float, s: float, n: float, proj: str, title_suffix: str) -> None:
        """Spawns a new tab with polar projection and coordinates."""
        base = self.display_config
        new_cfg = replace(base, region=(w, e, s, n), projection=proj, projection_mode="manual",
                          title=f"{base.title} {title_suffix}", slice_indices=dict(base.slice_indices))
        self.spawn_subregion_tab.emit(new_cfg)

    def _on_box_selected(self, w: float, e: float, s: float, n: float) -> None:
        """When user box-selects a region on the canvas, spawn a new sub-region PlotConfig."""
        base = self.display_config
        projection = base.projection
        policy = base.projection_mode
        if policy == "auto" or projection == "IntMollOcean":
            projection = GMTEngine.get_recommended_projections((w, e, s, n), base.variable_name, {"description": base.variable_description})[0][1] if base.is_geographic else "X16c/10c"
            policy = "auto"
        new_cfg = replace(base, region=(w, e, s, n), projection=projection, projection_mode=policy,
                          title=f"{base.title} [{w:.1f}–{e:.1f}, {s:.1f}–{n:.1f}]", slice_indices=dict(base.slice_indices))
        self.act_pan.setChecked(True)
        self.canvas.set_box_select_mode(False)
        self.spawn_subregion_tab.emit(new_cfg)

    def _open_region_dialog(self) -> None:
        current_region = self.display_config.region or (0.0, 360.0, -90.0, 90.0)
        dlg = RegionDialog(current_region, self)
        if dlg.exec():
            w, e, s, n = dlg.get_region()
            if e > w and n > s:
                self._on_box_selected(w, e, s, n)
