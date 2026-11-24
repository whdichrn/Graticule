"""Shared, validated plotting controls; each plot restores its own dataset and slice."""
from dataclasses import replace
import os
from typing import Optional, Dict, Tuple
from PySide6 import QtCore, QtWidgets
from ..backend.nc_reader import DatasetMeta, VarMeta, NetCDFMetadataReader
from ..backend.gmt_engine import GMTEngine, PlotConfig, parse_gmt_conf


class ControlPanel(QtWidgets.QWidget):
    plot_requested = QtCore.Signal(object)
    auto_range_requested = QtCore.Signal(str, bool, str, object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._dataset_meta = None
        self._current_var = None
        self._slice_widgets = {}
        self._base_config = None
        self._syncing = False
        self._setup_ui()

    @staticmethod
    def _spin(minimum, maximum, value, decimals=4):
        spin = QtWidgets.QDoubleSpinBox()
        spin.setRange(minimum, maximum)
        spin.setDecimals(decimals)
        spin.setValue(value)
        spin.setKeyboardTracking(False)
        return spin

    @staticmethod
    def _page(tabs, label):
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QtWidgets.QFrame.Shape.NoFrame)
        widget = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(widget)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(12)
        layout.setAlignment(QtCore.Qt.AlignmentFlag.AlignTop)
        scroll.setWidget(widget)
        tabs.addTab(scroll, label)
        return layout

    @staticmethod
    def _group(layout, title):
        group = QtWidgets.QGroupBox(title)
        group.setSizePolicy(QtWidgets.QSizePolicy.Policy.Preferred, QtWidgets.QSizePolicy.Policy.Maximum)
        form = QtWidgets.QFormLayout(group)
        form.setFieldGrowthPolicy(QtWidgets.QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        form.setRowWrapPolicy(QtWidgets.QFormLayout.RowWrapPolicy.WrapLongRows)
        layout.addWidget(group)
        return form

    def _setup_ui(self):
        root = QtWidgets.QVBoxLayout(self)
        root.setContentsMargins(4, 4, 4, 4)
        self.lbl_source = QtWidgets.QLabel("Choose a grid in Dataset Explorer")
        self.lbl_source.setWordWrap(True)
        root.addWidget(self.lbl_source)
        tabs = QtWidgets.QTabWidget()
        root.addWidget(tabs)
        map_page = self._page(tabs, "Map")
        colors = self._page(tabs, "Color / Layers")
        style = self._page(tabs, "Style / GMT")
        self.slice_group = QtWidgets.QGroupBox("Dimension slices")
        self.slice_layout = QtWidgets.QVBoxLayout(self.slice_group)
        map_page.addWidget(self.slice_group)
        form = self._group(map_page, "Projection")
        self.chk_auto_projection = QtWidgets.QCheckBox("Recommend automatically for the region")
        self.chk_auto_projection.setChecked(True)
        form.addRow(self.chk_auto_projection)
        self.proj_combo = QtWidgets.QComboBox()
        self.proj_combo.setEditable(True)
        self.proj_combo.setInsertPolicy(QtWidgets.QComboBox.InsertPolicy.NoInsert)
        self.proj_combo.setSizeAdjustPolicy(QtWidgets.QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        self.proj_combo.setMinimumContentsLength(18)
        self.proj_combo.setToolTip("Choose a projection or type a GMT code such as L120/30/25/35/16c. Manual choices stay fixed when bounds change.")
        form.addRow("Projection / -J", self.proj_combo)
        self.proj_combo.activated.connect(lambda _: self.chk_auto_projection.setChecked(False))
        self.proj_combo.lineEdit().textEdited.connect(lambda _: self.chk_auto_projection.setChecked(False))
        self.chk_auto_projection.toggled.connect(self._on_region_edited)
        form = self._group(map_page, "Region / -R")
        self.spin_west = self._spin(-1e12, 1e12, 0, 6)
        self.spin_east = self._spin(-1e12, 1e12, 360, 6)
        self.spin_south = self._spin(-1e12, 1e12, -90, 6)
        self.spin_north = self._spin(-1e12, 1e12, 90, 6)
        for name, spin in (("West / X min", self.spin_west), ("East / X max", self.spin_east), ("South / Y min", self.spin_south), ("North / Y max", self.spin_north)):
            form.addRow(name, spin)
            spin.editingFinished.connect(self._on_region_edited)
        self.btn_reset_region = QtWidgets.QPushButton("Full dataset extent")
        self.btn_reset_region.clicked.connect(self._reset_to_full_region)
        form.addRow(self.btn_reset_region)
        self.edit_title = QtWidgets.QLineEdit()
        form.addRow("Title", self.edit_title)
        map_page.addStretch()

        form = self._group(colors, "Palette and range")
        self.cpt_combo = QtWidgets.QComboBox()
        self.cpt_combo.setEditable(True)
        self.cpt_combo.addItems(GMTEngine.CPT_OPTIONS)
        self.cpt_combo.setCurrentText("turbo")
        self.cpt_combo.setToolTip("GMT palette name, comma-separated colors, or an absolute .cpt file path")
        form.addRow("Palette / -C", self.cpt_combo)
        self.chk_auto_cpt = QtWidgets.QCheckBox("Fit selected region and slice at render time")
        self.chk_auto_cpt.setChecked(True)
        form.addRow(self.chk_auto_cpt)
        self.chk_symmetric = QtWidgets.QCheckBox("Center automatic range on zero (±A)")
        form.addRow(self.chk_symmetric)
        self.spin_cmin = self._spin(-1e30, 1e30, -1, 8)
        self.spin_cmax = self._spin(-1e30, 1e30, 1, 8)
        form.addRow("Minimum", self.spin_cmin)
        form.addRow("Maximum", self.spin_cmax)
        for spin in (self.spin_cmin, self.spin_cmax):
            spin.valueChanged.connect(lambda _: self.chk_auto_cpt.setChecked(False) if not self._syncing else None)
        row = QtWidgets.QHBoxLayout()
        self.btn_auto_range = QtWidgets.QPushButton("Scan range")
        self.btn_sym_range = QtWidgets.QPushButton("Scan symmetric ±A")
        self.btn_auto_range.clicked.connect(lambda: self._on_auto_range_clicked(False))
        self.btn_sym_range.clicked.connect(lambda: self._on_auto_range_clicked(True))
        row.addWidget(self.btn_auto_range); row.addWidget(self.btn_sym_range)
        form.addRow(row)
        self.chk_reverse_cpt = QtWidgets.QCheckBox("Reverse colors (-Ic)")
        self.chk_continuous_cpt = QtWidgets.QCheckBox("Continuous colors (-Z)")
        self.chk_continuous_cpt.setChecked(True)
        form.addRow(self.chk_reverse_cpt)
        form.addRow(self.chk_continuous_cpt)
        self.spin_levels = QtWidgets.QSpinBox(); self.spin_levels.setRange(2, 4096); self.spin_levels.setValue(16)
        form.addRow("Discrete intervals", self.spin_levels)
        self.edit_colorbar_title = QtWidgets.QLineEdit()
        form.addRow("Colorbar label", self.edit_colorbar_title)
        self.edit_nan_color = QtWidgets.QLineEdit("gray90")
        form.addRow("Missing data color", self.edit_nan_color)

        form = self._group(colors, "Overlays and masking")
        self.combo_mask = QtWidgets.QComboBox()
        for label, code in (("None", "none"), ("Hide land (ocean only)", "land"), ("Hide ocean (land only)", "ocean")):
            self.combo_mask.addItem(label, code)
        form.addRow("Mask area", self.combo_mask)
        self.edit_mask_color = QtWidgets.QLineEdit("gray90"); form.addRow("Mask fill", self.edit_mask_color)
        self.chk_coast = QtWidgets.QCheckBox("Coastlines"); self.chk_coast.setChecked(True)
        self.chk_borders = QtWidgets.QCheckBox("Country borders")
        self.chk_frame = QtWidgets.QCheckBox("Frame & tick labels"); self.chk_frame.setChecked(True)
        self.chk_grid = QtWidgets.QCheckBox("Gridlines"); self.chk_grid.setChecked(True)
        self.chk_colorbar = QtWidgets.QCheckBox("Colorbar"); self.chk_colorbar.setChecked(True)
        for widget in (self.chk_coast, self.chk_borders, self.chk_frame, self.chk_grid, self.chk_colorbar): form.addRow(widget)
        self.combo_resolution = QtWidgets.QComboBox()
        for label, code in (("Crude", "c"), ("Low", "l"), ("Intermediate", "i"), ("High", "h"), ("Full", "f"), ("Auto", "a")): self.combo_resolution.addItem(label, code)
        self.combo_resolution.setCurrentIndex(1); form.addRow("Coast detail", self.combo_resolution)
        self.edit_coast_pen = QtWidgets.QLineEdit("0.4p,gray25"); form.addRow("Coast pen", self.edit_coast_pen)
        colors.addStretch()

        form = self._group(style, "Typography and ticks")
        self.spin_title_size = self._spin(1, 72, 14, 1)
        self.spin_annot_size = self._spin(1, 72, 10, 1)
        self.spin_label_size = self._spin(1, 72, 11, 1)
        for label, widget in (("Title (pt)", self.spin_title_size), ("Tick labels (pt)", self.spin_annot_size), ("Axis labels (pt)", self.spin_label_size)): form.addRow(label, widget)
        self.spin_x_interval = self._spin(0, 1e12, 0, 6); self.spin_x_interval.setSpecialValueText("Automatic")
        self.spin_y_interval = self._spin(0, 1e12, 0, 6); self.spin_y_interval.setSpecialValueText("Automatic")
        form.addRow("X tick/grid interval", self.spin_x_interval); form.addRow("Y tick/grid interval", self.spin_y_interval)
        self.edit_frame_sides = QtWidgets.QLineEdit("WSen"); form.addRow("Frame sides", self.edit_frame_sides)
        self.combo_interpolation = QtWidgets.QComboBox()
        for label, code in (("Bicubic", "c"), ("Bilinear", "l"), ("Nearest neighbor", "n"), ("B-spline", "b")): self.combo_interpolation.addItem(label, code)
        form.addRow("Interpolation", self.combo_interpolation)
        self.spin_dpi = QtWidgets.QSpinBox(); self.spin_dpi.setRange(36, 2400); self.spin_dpi.setValue(150)
        form.addRow("DPI", self.spin_dpi)
        self.chk_preview = QtWidgets.QCheckBox("Fast preview for large grids (export uses full data)"); self.chk_preview.setChecked(True); form.addRow(self.chk_preview)
        form = self._group(style, "GMT command options")
        hint = QtWidgets.QLabel("Enter arguments for each GMT module. Quote values containing spaces. Projection and region use the Map controls.")
        hint.setWordWrap(True); form.addRow(hint)
        for attr, label, placeholder in (("edit_extra_args", "grdimage", "-BWSen -t20"), ("edit_makecpt_args", "makecpt", "-G-50/50"), ("edit_coast_args", "coast", "-A1000"), ("edit_colorbar_args", "colorbar", "-Bxa20f10"), ("edit_gmt_conf", "gmt.conf", "MAP_FRAME_TYPE=plain, FONT_TITLE=14p,Helvetica,black")):
            edit = QtWidgets.QLineEdit(); edit.setPlaceholderText(placeholder); edit.setToolTip(placeholder); setattr(self, attr, edit); form.addRow(label, edit)
        row = QtWidgets.QHBoxLayout()
        for label, callback in (("Plain frame", lambda: self._set_conf_kv("MAP_FRAME_TYPE", "plain")), ("D:M:S ticks", lambda: self._set_conf_kv("FORMAT_GEO_MAP", "ddd:mm:ssF")), ("Clear", self._clear_overrides)):
            btn = QtWidgets.QPushButton(label); btn.clicked.connect(callback); row.addWidget(btn)
        form.addRow(row); style.addStretch()
        self.lbl_error = QtWidgets.QLabel(); self.lbl_error.setWordWrap(True); self.lbl_error.setStyleSheet("color: #b42318;"); root.addWidget(self.lbl_error)
        self.btn_apply = QtWidgets.QPushButton("Render active plot"); self.btn_apply.setObjectName("btn_apply"); self.btn_apply.setEnabled(False); self.btn_apply.clicked.connect(self.trigger_render); root.addWidget(self.btn_apply)
        self.update_projections_for_region(None)

    def _set_conf_kv(self, key, val):
        try:
            conf = parse_gmt_conf(self.edit_gmt_conf.text()); conf[key] = val
            self.edit_gmt_conf.setText(", ".join(f"{k}={v}" for k, v in conf.items()))
        except ValueError as exc: self.lbl_error.setText(str(exc))

    def _clear_overrides(self):
        for edit in (self.edit_extra_args, self.edit_makecpt_args, self.edit_coast_args, self.edit_colorbar_args, self.edit_gmt_conf): edit.clear()

    def _projection(self):
        idx = self.proj_combo.currentIndex()
        text = self.proj_combo.currentText().strip()
        return self.proj_combo.itemData(idx) if idx >= 0 and text == self.proj_combo.itemText(idx) else text.removeprefix("-J")

    def _region(self):
        return tuple(w.value() for w in (self.spin_west, self.spin_east, self.spin_south, self.spin_north))

    def update_projections_for_region(self, region):
        current = self._projection()
        projs = GMTEngine.get_recommended_projections(region, self._current_var.name if self._current_var else "", self._current_var.attrs if self._current_var else None)
        if self._current_var and not self._current_var.is_geographic: projs = [("Cartesian linear", "X16c/10c", "Linear")]
        blocker = QtCore.QSignalBlocker(self.proj_combo)
        self.proj_combo.clear()
        seen = set()
        for i, (label, code, category) in enumerate(projs):
            if code not in seen:
                self.proj_combo.addItem(f"{code} - {category}" + (" (recommended)" if i == 0 else ""), code)
                self.proj_combo.setItemData(self.proj_combo.count()-1, label, QtCore.Qt.ItemDataRole.ToolTipRole)
                seen.add(code)
        chosen = projs[0][1] if self.chk_auto_projection.isChecked() else current
        if chosen and self.proj_combo.findData(chosen) < 0: self.proj_combo.addItem(f"Custom ({chosen})", chosen)
        self.proj_combo.setCurrentIndex(max(0, self.proj_combo.findData(chosen)))
        self.proj_combo.lineEdit().setCursorPosition(0)

    def _on_region_edited(self, *_):
        if not self._syncing: self.update_projections_for_region(self._region())

    def set_dataset(self, meta):
        if not self._dataset_meta or self._dataset_meta.file_path != meta.file_path:
            self._current_var = None
            self._base_config = None
            self.btn_apply.setEnabled(False)
            self.lbl_source.setText(f"{os.path.basename(meta.file_path)} / Choose a grid variable")
            self.lbl_source.setToolTip(meta.file_path)
        self._dataset_meta = meta

    def set_variable(self, var, auto_fetch_range=False):
        self._current_var = var
        self.btn_apply.setEnabled(True)
        self._base_config = None
        self.lbl_source.setText(f"{os.path.basename(self._dataset_meta.file_path)} / {var.name}")
        self.lbl_source.setToolTip(self._dataset_meta.file_path)
        self.edit_title.setText(var.display_title)
        self.edit_colorbar_title.setText(str(var.attrs.get("units", "")))
        self._build_slice_controls(var)
        if var.x_range and var.y_range: self.set_region(*var.x_range, *var.y_range)
        self.chk_auto_cpt.setChecked(True)
        symmetric = any(k in var.name.lower() for k in ("txx", "tyy", "tzz", "txy", "txz", "tyz", "anom", "dov"))
        self.chk_symmetric.setChecked(symmetric)
        name = var.name.lower()
        self.cpt_combo.setCurrentText("polar" if symmetric else "relief" if any(k in name for k in ("elev", "dem", "topo", "altitude")) else "ocean" if any(k in name for k in ("bathy", "depth")) else "turbo")
        self.lbl_error.clear()
        if auto_fetch_range: self._on_auto_range_clicked()

    def _build_slice_controls(self, var):
        while self.slice_layout.count():
            item = self.slice_layout.takeAt(0)
            if item.widget(): item.widget().deleteLater()
        self._slice_widgets.clear()
        self.slice_group.setVisible(bool(var.slice_dims))
        self.slice_group.parentWidget().layout().invalidate()
        for dim in var.slice_dims:
            container = QtWidgets.QWidget(); form = QtWidgets.QFormLayout(container); form.setContentsMargins(0, 0, 0, 0)
            slider = QtWidgets.QSlider(QtCore.Qt.Orientation.Horizontal)
            spin = QtWidgets.QSpinBox()
            size = self._dataset_meta.dimensions[dim]
            slider.setRange(0, size-1); spin.setRange(0, size-1)
            spin.setKeyboardTracking(False)
            label = QtWidgets.QLabel()
            coords = self._dataset_meta.dimension_coords.get(dim, [])
            def update(index, values=coords, target=label): target.setText(str(values[index]) if index < len(values) else str(index))
            slider.valueChanged.connect(spin.setValue); spin.valueChanged.connect(slider.setValue); slider.valueChanged.connect(update)
            slider.sliderReleased.connect(self.trigger_render)
            spin.editingFinished.connect(self.trigger_render)
            form.addRow(f"{dim} (0–{size-1})", spin); form.addRow(slider); form.addRow(label)
            self.slice_layout.addWidget(container); self._slice_widgets[dim] = (slider, spin, label); update(0)

    def _reset_to_full_region(self):
        if self._current_var and self._current_var.x_range and self._current_var.y_range: self.set_region(*self._current_var.x_range, *self._current_var.y_range)

    def set_region(self, w, e, s, n):
        for widget, value in zip((self.spin_west, self.spin_east, self.spin_south, self.spin_north), (w, e, s, n)): widget.setValue(value)
        self.update_projections_for_region((w, e, s, n))

    def set_cpt_range(self, cmin, cmax):
        if cmin == cmax: cmin -= 1; cmax += 1
        self.spin_cmin.setValue(cmin); self.spin_cmax.setValue(cmax); self.chk_auto_cpt.setChecked(False)

    def _on_auto_range_clicked(self, symmetric=False):
        if self._dataset_meta and self._current_var: self.auto_range_requested.emit(self.get_current_grid_spec(), symmetric, self.combo_mask.currentData(), self._region())

    def get_slice_indices(self):
        return {dim: widgets[1].value() for dim, widgets in self._slice_widgets.items()}

    def get_current_grid_spec(self):
        if not self._dataset_meta or not self._current_var: return ""
        return NetCDFMetadataReader.build_gmt_grid_spec(self._dataset_meta.file_path, self._current_var, self.get_slice_indices())

    def sync_from_config(self, cfg):
        self._syncing = True
        try:
            self._base_config = cfg
            self.chk_auto_projection.setChecked(cfg.projection_mode == "auto")
            if cfg.region: self.set_region(*cfg.region)
            idx = self.proj_combo.findData(cfg.projection)
            if idx < 0: self.proj_combo.addItem(f"Custom ({cfg.projection})", cfg.projection); idx = self.proj_combo.count()-1
            self.proj_combo.setCurrentIndex(idx)
            for dim, index in cfg.slice_indices.items():
                if dim in self._slice_widgets: self._slice_widgets[dim][1].setValue(index)
            for attr, value in (("edit_title", cfg.title), ("edit_colorbar_title", cfg.colorbar_title), ("edit_mask_color", cfg.mask_color), ("edit_nan_color", cfg.nan_color), ("edit_coast_pen", cfg.coast_pen), ("edit_frame_sides", cfg.frame_sides), ("edit_extra_args", cfg.extra_args), ("edit_makecpt_args", cfg.makecpt_args), ("edit_coast_args", cfg.coast_args), ("edit_colorbar_args", cfg.colorbar_args), ("edit_gmt_conf", cfg.gmt_conf)): getattr(self, attr).setText(value)
            self.cpt_combo.setCurrentText(cfg.cpt)
            for combo, value in ((self.combo_mask, cfg.mask_mode), (self.combo_resolution, cfg.coast_resolution), (self.combo_interpolation, cfg.interpolation)): combo.setCurrentIndex(combo.findData(value))
            for widget, value in ((self.chk_symmetric, cfg.symmetric_cpt), (self.chk_reverse_cpt, cfg.cpt_reverse), (self.chk_continuous_cpt, cfg.cpt_continuous), (self.chk_coast, cfg.show_coast), (self.chk_borders, cfg.show_borders), (self.chk_frame, cfg.show_frame), (self.chk_grid, cfg.show_grid), (self.chk_colorbar, cfg.show_colorbar), (self.chk_preview, cfg.preview)): widget.setChecked(value)
            if cfg.cpt_range: self.spin_cmin.setValue(cfg.cpt_range[0]); self.spin_cmax.setValue(cfg.cpt_range[1])
            self.chk_auto_cpt.setChecked(cfg.cpt_range is None)
            for widget, value in ((self.spin_title_size, cfg.title_size), (self.spin_annot_size, cfg.annotation_size), (self.spin_label_size, cfg.label_size), (self.spin_x_interval, cfg.x_interval), (self.spin_y_interval, cfg.y_interval), (self.spin_dpi, cfg.dpi), (self.spin_levels, cfg.cpt_levels)): widget.setValue(value)
            self.lbl_error.clear()
        finally: self._syncing = False

    def get_plot_config(self):
        if not self._dataset_meta or not self._current_var: return None
        cfg = replace(self._base_config) if self._base_config else PlotConfig(grid_spec="")
        cfg.grid_spec = self.get_current_grid_spec(); cfg.region = self._region(); cfg.projection = self._projection()
        cfg.projection_mode = "auto" if self.chk_auto_projection.isChecked() else "manual"
        cfg.source_path = self._dataset_meta.file_path; cfg.variable_name = self._current_var.name; cfg.slice_indices = self.get_slice_indices(); cfg.is_geographic = self._current_var.is_geographic
        cfg.variable_description = " ".join(str(self._current_var.attrs.get(k, "")) for k in ("standard_name", "long_name", "units", "comment", "description")).strip()
        cfg.cpt = self.cpt_combo.currentText(); cfg.cpt_range = None if self.chk_auto_cpt.isChecked() else (self.spin_cmin.value(), self.spin_cmax.value())
        for name, widget in (("symmetric_cpt", self.chk_symmetric), ("cpt_reverse", self.chk_reverse_cpt), ("cpt_continuous", self.chk_continuous_cpt), ("show_coast", self.chk_coast), ("show_borders", self.chk_borders), ("show_frame", self.chk_frame), ("show_grid", self.chk_grid), ("show_colorbar", self.chk_colorbar), ("preview", self.chk_preview)): setattr(cfg, name, widget.isChecked())
        for name, edit in (("title", self.edit_title), ("colorbar_title", self.edit_colorbar_title), ("mask_color", self.edit_mask_color), ("nan_color", self.edit_nan_color), ("coast_pen", self.edit_coast_pen), ("frame_sides", self.edit_frame_sides), ("extra_args", self.edit_extra_args), ("makecpt_args", self.edit_makecpt_args), ("coast_args", self.edit_coast_args), ("colorbar_args", self.edit_colorbar_args), ("gmt_conf", self.edit_gmt_conf)): setattr(cfg, name, edit.text().strip())
        cfg.mask_mode = self.combo_mask.currentData(); cfg.coast_resolution = self.combo_resolution.currentData(); cfg.interpolation = self.combo_interpolation.currentData()
        for name, widget in (("title_size", self.spin_title_size), ("annotation_size", self.spin_annot_size), ("label_size", self.spin_label_size), ("x_interval", self.spin_x_interval), ("y_interval", self.spin_y_interval), ("dpi", self.spin_dpi), ("cpt_levels", self.spin_levels)): setattr(cfg, name, widget.value())
        cfg.validate()
        return cfg

    def trigger_render(self):
        try:
            cfg = self.get_plot_config()
            self.lbl_error.clear()
            if cfg: self.plot_requested.emit(cfg)
        except (ValueError, OSError) as exc: self.lbl_error.setText(str(exc))
