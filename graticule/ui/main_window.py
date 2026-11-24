"""
Main Application Window.
Coordinates dataset loading, tree explorer, control panel, multi-tab plot viewer,
non-blocking asynchronous GMT background rendering, and export capabilities.
All labels, messages, dialogs, and text are in English without emojis.
"""

from typing import Optional, Dict, List
import os
import time
import tempfile
import subprocess
import shutil
from dataclasses import replace
from collections import OrderedDict
import numpy as np
from PySide6 import QtCore, QtGui, QtWidgets

from ..backend.nc_reader import NetCDFMetadataReader, DatasetMeta, VarMeta
from ..backend.gmt_engine import GMTEngine, PlotConfig
from .dataset_tree import DatasetTreeWidget
from .control_panel import ControlPanel
from .plot_tab_view import PlotTabView


class GMTRenderThread(QtCore.QThread):
    """Clean background thread executing GMT rendering without event loop deadlocks."""
    finished_render = QtCore.Signal(int, object, str, float)  # (request_id, tab_view, output_path, elapsed)
    error_render = QtCore.Signal(int, object, str)            # (request_id, tab_view, err_msg)

    def __init__(self, request_id: int, tab_view: PlotTabView, engine: GMTEngine, config: PlotConfig, output_path: str, parent=None):
        super().__init__(parent)
        self.request_id = request_id
        self.tab_view = tab_view
        self.engine = engine
        self.config = config
        self.output_path = output_path
        self.is_export = False
        self.hover_lookup = None

    def run(self):
        t0 = time.perf_counter()
        try:
            resolved = self.engine.render(self.config, self.output_path)
            self.config = replace(resolved, cpt_range=self.config.cpt_range)
            if not self.is_export and not self.isInterruptionRequested():
                uv = np.linspace(0, 1, 129)
                u, v = np.meshgrid(uv, uv)
                dims = self.engine.get_map_dimensions_cm(self.config.region, self.config.projection, self.config.gmt_conf)
                self.hover_lookup = self.engine.inverse_project_points(np.column_stack((u.ravel(), v.ravel())), self.config.region, self.config.projection, dims, self.config.gmt_conf).reshape(129, 129, 2)
            elapsed = time.perf_counter() - t0
            self.finished_render.emit(self.request_id, self.tab_view, self.output_path, elapsed)
        except Exception as e:
            self.error_render.emit(self.request_id, self.tab_view, str(e))


class RangeThread(QtCore.QThread):
    result = QtCore.Signal(str, object, str, float, float)
    error = QtCore.Signal(str)

    def __init__(self, engine, grid, symmetric, mask, region, parent):
        super().__init__(parent)
        self.engine, self.grid, self.symmetric, self.mask, self.region = engine, grid, symmetric, mask, region

    def run(self):
        try:
            info = self.engine.get_masked_grid_info(self.grid, self.region, self.mask)
            lo, hi = info["z_min"], info["z_max"]
            if self.symmetric: hi = max(abs(lo), abs(hi)); lo = -hi
            self.result.emit(self.grid, self.region, self.mask, lo, hi)
        except Exception as exc: self.error.emit(str(exc))


class ScriptEditorDialog(QtWidgets.QDialog):
    """Interactive GMT script viewer and editor with live synchronization and execution."""

    def __init__(self, script: str, config: PlotConfig, engine: GMTEngine, parent=None):
        super().__init__(parent)
        self.setWindowTitle("GMT Modern Mode Script Editor & Sync")
        self.resize(750, 520)
        self.script = script
        self.config = config
        self.engine = engine
        self.applied_config: Optional[PlotConfig] = None
        self.custom_render_path: Optional[str] = None
        self._setup_ui()

    def _setup_ui(self):
        vbox = QtWidgets.QVBoxLayout(self)
        vbox.setSpacing(8)

        lbl_hint = QtWidgets.QLabel(
            "Edit the GMT Modern Mode script below. You can apply changes to GUI controls and re-render, "
            "or run the script directly via bash."
        )
        lbl_hint.setStyleSheet("color: #444; font-size: 11px;")
        vbox.addWidget(lbl_hint)

        self.text_edit = QtWidgets.QPlainTextEdit()
        self.text_edit.setPlainText(self.script)
        font = QtGui.QFont("Menlo" if "Menlo" in QtGui.QFontDatabase.families() else "Courier New", 12)
        self.text_edit.setFont(font)
        self.text_edit.setStyleSheet("background-color: #fbfbfb; border: 1px solid #ccc; ")
        vbox.addWidget(self.text_edit)

        btn_row = QtWidgets.QHBoxLayout()
        self.btn_apply = QtWidgets.QPushButton("Apply to GUI & Render")
        self.btn_apply.setToolTip("Parse modified parameters (-J, -R, -C, -T, etc.) into GUI options and re-render")
        self.btn_apply.setStyleSheet("font-weight: bold; background-color: #0d6efd; color: white; padding: 6px 12px; border-radius: 4px;")
        self.btn_apply.clicked.connect(self._on_apply)

        self.btn_run = QtWidgets.QPushButton("Run Script Directly")
        self.btn_run.setToolTip("Execute the standalone script via bash and display output image")
        self.btn_run.setStyleSheet("font-weight: bold; padding: 6px 12px;")
        self.btn_run.clicked.connect(self._on_run_script)

        self.btn_copy = QtWidgets.QPushButton("Copy to Clipboard")
        self.btn_copy.clicked.connect(lambda: QtWidgets.QApplication.clipboard().setText(self.text_edit.toPlainText()))

        self.btn_close = QtWidgets.QPushButton("Close")
        self.btn_close.clicked.connect(self.reject)

        btn_row.addWidget(self.btn_apply)
        btn_row.addWidget(self.btn_run)
        btn_row.addStretch()
        btn_row.addWidget(self.btn_copy)
        btn_row.addWidget(self.btn_close)
        vbox.addLayout(btn_row)

    def _on_apply(self):
        text = self.text_edit.toPlainText()
        try:
            self.applied_config = GMTEngine.parse_script_to_config(text, self.config)
            self.accept()
        except (ValueError, RuntimeError) as exc:
            QtWidgets.QMessageBox.warning(self, "Cannot synchronize script", str(exc))

    def _on_run_script(self):
        if getattr(self, "_script_process", None) and self._script_process.state() != QtCore.QProcess.ProcessState.NotRunning:
            return
        self._script_owner = tempfile.TemporaryDirectory(prefix="graticule_script_")
        td = self._script_owner.name
        script_path = os.path.join(td, "run_plot.sh")
        with open(script_path, "w", encoding="utf-8") as stream:
            stream.write(self.text_edit.toPlainText())
        env = QtCore.QProcessEnvironment.systemEnvironment()
        env.insert("PATH", os.path.dirname(self.engine.gmt_bin)+os.pathsep+env.value("PATH"))
        process = QtCore.QProcess(self)
        process.setProcessEnvironment(env)
        process.setWorkingDirectory(td)
        self._script_process = process
        self.btn_run.setEnabled(False); self.btn_apply.setEnabled(False)
        self.btn_close.setEnabled(False)
        self.text_edit.setReadOnly(True)
        self.btn_run.setText("Running GMT script…")
        process.finished.connect(self._script_finished)
        process.errorOccurred.connect(self._script_process_error)
        process.start("bash", [script_path])

    def _script_process_error(self, error):
        if error == QtCore.QProcess.ProcessError.FailedToStart:
            self._finish_script_ui()
            QtWidgets.QMessageBox.critical(self, "Script error", self._script_process.errorString())
            self._script_owner.cleanup()

    def _finish_script_ui(self):
        self.btn_run.setEnabled(True); self.btn_apply.setEnabled(True); self.btn_close.setEnabled(True)
        self.btn_run.setText("Run Script Directly"); self.text_edit.setReadOnly(False)

    def _script_finished(self, exit_code, exit_status):
        self._finish_script_ui()
        stderr = bytes(self._script_process.readAllStandardError()).decode(errors="replace")
        stdout = bytes(self._script_process.readAllStandardOutput()).decode(errors="replace")
        try:
            if exit_code:
                QtWidgets.QMessageBox.critical(self, "Script error", (stderr or stdout)[-12000:])
                return
            td = self._script_owner.name
            files = [os.path.join(td, f) for f in os.listdir(td) if f.lower().endswith((".png", ".jpg", ".jpeg", ".tif", ".tiff"))]
            if not files:
                QtWidgets.QMessageBox.information(self, "Script completed", "The script completed without a raster preview in its working directory. Inspect its output paths, or export PNG for a preview.")
                return
            found = max(files, key=os.path.getmtime)
            if QtGui.QImage(found).isNull():
                raise ValueError("The script output is not a readable raster image.")
            folder = self.parent()._render_owner.name
            descriptor, path = tempfile.mkstemp(prefix="custom_", suffix=os.path.splitext(found)[1], dir=folder)
            os.close(descriptor); shutil.copyfile(found, path)
            self.custom_render_path = path
            try:
                self.applied_config = GMTEngine.parse_script_to_config(self.text_edit.toPlainText(), self.config)
            except ValueError:
                self.applied_config = None
            self.accept()
        except (OSError, ValueError) as exc:
            QtWidgets.QMessageBox.critical(self, "Script preview error", str(exc))
        finally:
            self._script_owner.cleanup()

    def reject(self):
        if getattr(self, "_script_process", None) and self._script_process.state() != QtCore.QProcess.ProcessState.NotRunning:
            return
        super().reject()


class MainWindow(QtWidgets.QMainWindow):
    """Main window for the Graticule application."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Graticule - NetCDF Viewer")
        self.resize(1360, 860)

        # Initialize GMT Engine
        try:
            self.engine = GMTEngine()
        except RuntimeError as e:
            QtWidgets.QMessageBox.critical(self, "GMT Not Found", str(e))
            self.engine = None

        self.current_meta: Optional[DatasetMeta] = None
        self._request_counter = 0
        self.datasets = {}
        self._workers = {}
        self._pending = OrderedDict()
        self._closing = False
        self._render_owner = tempfile.TemporaryDirectory(prefix="graticule_views_")

        from .theme import apply_macos_theme
        qapp = QtWidgets.QApplication.instance()
        if qapp:
            apply_macos_theme(qapp, self)

        self._setup_ui()
        self._setup_menus()
        self._setup_toolbar()
        self._setup_connections()

    def _setup_ui(self) -> None:
        splitter = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        self.setCentralWidget(splitter)

        # Left side: Tab widget with Tree Explorer & Plot Controls
        self.left_tabs = QtWidgets.QTabWidget()
        self.left_tabs.setMinimumWidth(390)
        self.left_tabs.setMaximumWidth(620)

        self.dataset_tree = DatasetTreeWidget()
        self.control_panel = ControlPanel()

        self.left_tabs.addTab(self.dataset_tree, "Dataset Explorer")
        self.left_tabs.addTab(self.control_panel, "Plot Controls")
        splitter.addWidget(self.left_tabs)

        # Right side: Multi-Tab Plot Viewer
        self.plot_tabs = QtWidgets.QTabWidget()
        self.plot_tabs.setTabsClosable(True)
        self.plot_tabs.setMovable(True)
        self.plot_tabs.tabCloseRequested.connect(self._on_tab_close_requested)
        self.plot_tabs.currentChanged.connect(self._on_current_tab_changed)

        splitter.addWidget(self.plot_tabs)
        splitter.setStretchFactor(0, 1)
        splitter.setStretchFactor(1, 3)
        splitter.setSizes([420, 940])

        # Status Bar
        self.status_bar = self.statusBar()
        self.status_lbl_file = QtWidgets.QLabel("No dataset loaded")
        self.status_lbl_coords = QtWidgets.QLabel("Lon: -- , Lat: --")
        self.status_lbl_time = QtWidgets.QLabel("Ready")
        self.status_progress = QtWidgets.QProgressBar()
        self.status_progress.setMaximumWidth(120)
        self.status_progress.setVisible(False)

        self.status_bar.addWidget(self.status_lbl_file, stretch=2)
        self.status_bar.addPermanentWidget(self.status_lbl_coords)
        self.status_bar.addPermanentWidget(self.status_progress)
        self.status_bar.addPermanentWidget(self.status_lbl_time)

    def _setup_menus(self) -> None:
        menubar = self.menuBar()

        # File Menu
        file_menu = menubar.addMenu("&File")

        act_open = QtGui.QAction("&Open Dataset...", self)
        act_open.setShortcut(QtGui.QKeySequence.StandardKey.Open)
        act_open.triggered.connect(self.open_file_dialog)
        file_menu.addAction(act_open)

        file_menu.addSeparator()

        self.act_export_img = QtGui.QAction("&Export Image (PNG, PDF, SVG)...", self)
        self.act_export_img.setShortcut(QtGui.QKeySequence.StandardKey.Save)
        self.act_export_img.triggered.connect(self.export_image_dialog)
        file_menu.addAction(self.act_export_img)

        self.act_export_script = QtGui.QAction("Export &GMT Script (Bash)...", self)
        self.act_export_script.triggered.connect(self.export_script_dialog)
        file_menu.addAction(self.act_export_script)

        file_menu.addSeparator()

        act_exit = QtGui.QAction("E&xit", self)
        act_exit.setShortcut(QtGui.QKeySequence.StandardKey.Quit)
        act_exit.triggered.connect(self.close)
        file_menu.addAction(act_exit)

        # View Menu
        view_menu = menubar.addMenu("&View")
        act_close_tab = QtGui.QAction("&Close Active Tab", self)
        act_close_tab.setShortcut(QtGui.QKeySequence.StandardKey.Close)
        act_close_tab.triggered.connect(self.close_current_tab_or_window)
        view_menu.addAction(act_close_tab)

        # Help Menu
        help_menu = menubar.addMenu("&Help")
        act_about = QtGui.QAction("&About Graticule", self)
        act_about.triggered.connect(self._show_about)
        help_menu.addAction(act_about)

    def _setup_toolbar(self) -> None:
        toolbar = self.addToolBar("Main Toolbar")
        toolbar.setMovable(False)
        toolbar.setToolButtonStyle(QtCore.Qt.ToolButtonStyle.ToolButtonTextBesideIcon)

        act_open = toolbar.addAction("Open")
        act_open.setIcon(self.style().standardIcon(QtWidgets.QStyle.StandardPixmap.SP_DialogOpenButton))
        act_open.triggered.connect(self.open_file_dialog)

        toolbar.addSeparator()

        act_render = toolbar.addAction("Render")
        act_render.setIcon(self.style().standardIcon(QtWidgets.QStyle.StandardPixmap.SP_BrowserReload))
        act_render.triggered.connect(self.control_panel.trigger_render)

        toolbar.addSeparator()

        act_script = toolbar.addAction("GMT Script")
        act_script.setIcon(self.style().standardIcon(QtWidgets.QStyle.StandardPixmap.SP_FileDialogContentsView))
        act_script.triggered.connect(self.show_script_viewer)

        act_export = toolbar.addAction("Export Image")
        act_export.setIcon(self.style().standardIcon(QtWidgets.QStyle.StandardPixmap.SP_DialogSaveButton))
        act_export.triggered.connect(self.export_image_dialog)

    def _setup_connections(self) -> None:
        self.dataset_tree.dataset_selected.connect(self._on_dataset_selected)
        self.dataset_tree.dataset_close_requested.connect(self._close_dataset)
        self.dataset_tree.variable_selected.connect(self._on_variable_inspected)
        self.dataset_tree.variable_activated.connect(self._on_variable_activated)
        self.dataset_tree.plot_in_new_tab.connect(self._on_variable_plot_new_tab)

        self.control_panel.plot_requested.connect(self._on_control_panel_render)
        self.control_panel.auto_range_requested.connect(self._on_auto_range_requested)

    def open_file(self, file_path: str, variable_name=None) -> None:
        try:
            path = os.path.realpath(file_path)
            if path in self.datasets:
                self._on_dataset_selected(self.datasets[path])
                return
            meta = NetCDFMetadataReader.open(path)
            self.datasets[path] = meta
            self._on_dataset_selected(meta)
            self.dataset_tree.load_dataset(meta)
            var = meta.variables.get(variable_name) if variable_name else next((v for v in meta.variables.values() if v.is_2d_plotable), None)
            if var and var.is_2d_plotable:
                self._on_variable_plot_new_tab(var)
            else:
                self.left_tabs.setCurrentWidget(self.dataset_tree)
                self.status_lbl_time.setText("No supported regular 2D grid; inspect variable details.")
        except Exception as exc:
            QtWidgets.QMessageBox.critical(self, "Failed to open dataset", f"{file_path}\n\n{exc}")

    def _on_dataset_selected(self, meta):
        self.current_meta = meta
        self.control_panel.set_dataset(meta)
        self.status_lbl_file.setText(f"{len(self.datasets)} datasets · {os.path.basename(meta.file_path)}")
        self.status_lbl_file.setToolTip(meta.file_path)

    def _close_dataset(self, meta):
        for i in range(self.plot_tabs.count()-1, -1, -1):
            tab = self.plot_tabs.widget(i)
            if tab.config.source_path == meta.file_path:
                self._on_tab_close_requested(i)
        self.dataset_tree.remove_dataset(meta.file_path)
        self.datasets.pop(meta.file_path, None)
        if self.current_meta and self.current_meta.file_path == meta.file_path:
            self.current_meta = None
            self.control_panel._dataset_meta = self.control_panel._current_var = None
            self.control_panel.lbl_source.setText("Choose a grid in Dataset Explorer")
            self.control_panel.btn_apply.setEnabled(False)
        self.status_lbl_file.setText(f"{len(self.datasets)} datasets open")

    def open_file_dialog(self) -> None:
        paths, _ = QtWidgets.QFileDialog.getOpenFileNames(self, "Open datasets", os.path.expanduser("~"),
            "NetCDF / HDF / GMT grids (*.nc *.nc4 *.cdf *.h5 *.hdf *.grd);;All files (*)")
        for path in paths:
            self.open_file(path)

    def _on_variable_inspected(self, var) -> None:
        if var and var.is_2d_plotable:
            panel = self.control_panel
            if panel._current_var is not var:
                panel.set_variable(var, auto_fetch_range=False)

    def _on_variable_activated(self, var: VarMeta) -> None:
        """When variable is double-clicked or 'Plot' button is clicked."""
        if self.control_panel._current_var is not var:
            self.control_panel.set_variable(var, auto_fetch_range=False)
        self.left_tabs.setCurrentWidget(self.control_panel)

        current_tab = self.get_active_tab_view()
        try:
            cfg = self.control_panel.get_plot_config()
        except ValueError as exc:
            self.control_panel.lbl_error.setText(str(exc))
            return
        if not cfg:
            return

        if current_tab is None:
            self._create_new_plot_tab(f"{os.path.basename(self.current_meta.file_path)} · {var.name}", cfg)
        else:
            current_tab.tab_title = f"{os.path.basename(self.current_meta.file_path)} · {var.name}"
            self.plot_tabs.setTabText(self.plot_tabs.currentIndex(), current_tab.tab_title)
            self._render_tab(current_tab, cfg)

    def _on_variable_plot_new_tab(self, var: VarMeta) -> None:
        """Explicitly plots the variable in a new tab."""
        if self.control_panel._current_var is not var:
            self.control_panel.set_variable(var, auto_fetch_range=False)
        self.left_tabs.setCurrentWidget(self.control_panel)
        try:
            cfg = self.control_panel.get_plot_config()
        except ValueError as exc:
            self.control_panel.lbl_error.setText(str(exc))
            return
        if cfg:
            self._create_new_plot_tab(f"{os.path.basename(self.current_meta.file_path)} · {var.name}", cfg)

    def _on_control_panel_render(self, cfg: PlotConfig) -> None:
        """Re-renders the currently active tab with settings from control panel."""
        active_tab = self.get_active_tab_view()
        if active_tab is None:
            title = cfg.title or "Plot"
            self._create_new_plot_tab(title, cfg)
        else:
            self._render_tab(active_tab, cfg)

    def _create_new_plot_tab(self, title: str, config: PlotConfig) -> PlotTabView:
        """Creates and adds a new PlotTabView to the multi-tab container."""
        tab_view = PlotTabView(title, config, self)
        tab_view.cursor_coordinates.connect(self._on_cursor_coords)
        tab_view.spawn_subregion_tab.connect(self._on_spawn_subregion_tab)
        tab_view.selection_message.connect(self.status_lbl_time.setText)

        idx = self.plot_tabs.addTab(tab_view, title)
        self.plot_tabs.setTabToolTip(idx, f"{title}\n{config.grid_spec}\n{tab_view._format_region_info()}")
        self.plot_tabs.setCurrentIndex(idx)

        self._render_tab(tab_view, config)
        return tab_view

    def _on_spawn_subregion_tab(self, sub_cfg: PlotConfig) -> None:
        """Handles box-selection from canvas: creates a new sub-region tab inheriting all settings."""
        if sub_cfg.region:
            w, e, s, n = sub_cfg.region
            title = f"Region [{w:.1f}~{e:.1f}, {s:.1f}~{n:.1f}]"
        else:
            title = "Subregion"

        new_tab = self._create_new_plot_tab(title, sub_cfg)
        self.control_panel.sync_from_config(sub_cfg)
        self.status_lbl_time.setText(f"Opened subregion tab: {title}")

    def _render_tab(self, tab_view, config):
        if not self.engine or self._closing: return
        self._request_counter += 1
        req = self._request_counter
        tab_view.latest_request = req
        tab_view.config = replace(config, slice_indices=dict(config.slice_indices))
        tab_view.canvas.setEnabled(False)
        output = os.path.join(self._render_owner.name, f"view_{req}.png")
        # At most two jobs execute; repeated requests for a tab replace its queued job.
        self._pending[(tab_view, False)] = (req, tab_view, tab_view.config, output, False)
        self._drain_jobs()

    def _drain_jobs(self):
        while not self._closing and self._pending and len(self._workers) < 2:
            _, (req, tab, cfg, output, is_export) = self._pending.popitem(last=False)
            if (getattr(tab, "_closed", False) or self.plot_tabs.indexOf(tab) < 0) and not is_export: continue
            thread = GMTRenderThread(req, tab, self.engine, cfg, output, self)
            thread.is_export = is_export
            thread.finished_render.connect(self._on_render_finished)
            thread.error_render.connect(self._on_render_error)
            thread.finished.connect(lambda request=req: self._worker_finished(request))
            self._workers[req] = thread
            thread.start()
        busy = bool(self._workers or self._pending)
        self.status_progress.setVisible(busy)
        self.status_progress.setRange(0, 0)
        if busy: self.status_lbl_time.setText(f"GMT: {len(self._workers)} running, {len(self._pending)} queued")

    def _worker_finished(self, request):
        thread = self._workers.pop(request, None)
        if thread: thread.deleteLater()
        self._drain_jobs()
        if self._closing and not self._workers and not getattr(self, "_range_workers", set()): self.close()

    def _on_render_finished(self, req_id, tab_view, output_path, elapsed):
        worker = self._workers.get(req_id)
        if not worker or self._closing: return
        if worker.is_export:
            self.status_lbl_time.setText(f"Exported {output_path} ({elapsed:.2f} s)")
            return
        if getattr(tab_view, "_closed", False) or self.plot_tabs.indexOf(tab_view) < 0 or tab_view.latest_request != req_id:
            self._discard_preview(output_path)
            return
        previous = tab_view.image_path
        tab_view.set_map_image(output_path, worker.config, self.engine, worker.hover_lookup)
        if previous and previous != output_path: self._discard_preview(previous)
        tab_view.canvas.setEnabled(True)
        if self.get_active_tab_view() is tab_view: self._restore_tab_context(tab_view)
        self.status_lbl_time.setText(f"Rendered in {elapsed:.2f} s")

    @staticmethod
    def _discard_preview(path):
        for item in (path, path+".map.json"):
            try: os.unlink(item)
            except FileNotFoundError: pass

    def _on_render_error(self, req_id, tab_view, err_msg):
        worker = self._workers.get(req_id)
        if not worker or self._closing: return
        if not worker.is_export:
            if getattr(tab_view, "_closed", False) or self.plot_tabs.indexOf(tab_view) < 0 or tab_view.latest_request != req_id: return
            tab_view.canvas.setEnabled(True)
        self.status_lbl_time.setText("GMT failed; see error details")
        QtWidgets.QMessageBox.critical(self, "GMT error", err_msg)

    def _on_auto_range_requested(self, grid_spec, is_symmetric, mask_mode="none", region=None):
        if not self.engine: return
        thread = RangeThread(self.engine, grid_spec, is_symmetric, mask_mode, region, self)
        thread.result.connect(self._on_range_result)
        thread.error.connect(lambda msg: self.status_lbl_time.setText(msg))
        thread.finished.connect(lambda: self._range_finished(thread))
        if not hasattr(self, "_range_workers"): self._range_workers = set()
        if self._range_workers: return
        self._range_workers.add(thread)
        self.control_panel.btn_auto_range.setEnabled(False)
        self.control_panel.btn_sym_range.setEnabled(False)
        self.status_lbl_time.setText("Scanning selected region and slice…")
        thread.start()

    def _on_range_result(self, grid, region, mask, lo, hi):
        panel = self.control_panel
        if (not self._closing and panel.get_current_grid_spec() == grid and panel._region() == tuple(region) and panel.combo_mask.currentData() == mask):
            panel.set_cpt_range(lo, hi)
            self.status_lbl_time.setText(f"Range: {lo:.6g} to {hi:.6g}")

    def _range_finished(self, thread):
        self._range_workers.discard(thread); thread.deleteLater()
        self.control_panel.btn_auto_range.setEnabled(True); self.control_panel.btn_sym_range.setEnabled(True)
        if self._closing and not self._workers and not self._range_workers: self.close()

    def _restore_tab_context(self, tab):
        cfg = tab.config
        path = cfg.source_path or cfg.grid_spec.split("?", 1)[0]
        meta = self.datasets.get(os.path.realpath(path))
        if not meta: return
        varname = cfg.variable_name or cfg.grid_spec.split("?", 1)[-1].split("[", 1)[0]
        var = meta.variables.get(varname)
        if not var: return
        self._on_dataset_selected(meta)
        self.control_panel.set_variable(var, auto_fetch_range=False)
        self.control_panel.sync_from_config(cfg)
        self.dataset_tree.select_variable(meta.file_path, var.name)

    def _on_current_tab_changed(self, idx):
        active = self.get_active_tab_view()
        if active: self._restore_tab_context(active)

    def _on_tab_close_requested(self, idx):
        widget = self.plot_tabs.widget(idx)
        if widget is None: return
        self._pending.pop((widget, False), None)
        if widget.image_path: self._discard_preview(widget.image_path)
        widget.latest_request = -1
        widget._closed = True
        self.plot_tabs.removeTab(idx)
        # Active workers retain Python references; they are ignored on completion.
        widget.deleteLater()
        self.status_lbl_coords.setText("Lon: -- , Lat: --")

    def close_current_tab_or_window(self) -> None:
        """Closes current tab, or closes window if only one or no tab remains."""
        if self.plot_tabs.count() > 1:
            idx = self.plot_tabs.currentIndex()
            if idx >= 0:
                self._on_tab_close_requested(idx)
        else:
            self.close()

    def get_active_tab_view(self) -> Optional[PlotTabView]:
        """Returns the currently active PlotTabView."""
        widget = self.plot_tabs.currentWidget()
        if isinstance(widget, PlotTabView):
            return widget
        return None

    def _on_cursor_coords(self, lon: float, lat: float) -> None:
        self.status_lbl_coords.setText(f"Lon: {lon:.3f}, Lat: {lat:.3f}")

    def export_image_dialog(self) -> None:
        """Exports high-resolution publication-quality image of the active tab."""
        active_tab = self.get_active_tab_view()
        if not self.engine or not active_tab or not active_tab.config:
            QtWidgets.QMessageBox.warning(self, "Notice", "No active plot to export.")
            return

        path, _ = QtWidgets.QFileDialog.getSaveFileName(
            self,
            "Export Publication Image",
            os.path.expanduser("~/Documents"),
            "PNG Image (*.png);;PDF Vector Document (*.pdf);;SVG Vector Graphic (*.svg);;TIFF Image (*.tif)"
        )
        if not path:
            return

        if not os.path.splitext(path)[1]: path += ".png"
        export_cfg = replace(active_tab.config, dpi=max(300, active_tab.config.dpi), preview=False)
        self._request_counter += 1
        self._pending[(active_tab, True, path)] = (self._request_counter, active_tab, export_cfg, path, True)
        self._drain_jobs()

    def export_script_dialog(self) -> None:
        """Exports reproducible GMT Bash script for the active tab."""
        active_tab = self.get_active_tab_view()
        if not self.engine or not active_tab or not active_tab.config:
            QtWidgets.QMessageBox.warning(self, "Notice", "No active plot to export.")
            return

        path, _ = QtWidgets.QFileDialog.getSaveFileName(
            self,
            "Export GMT Bash Script",
            os.path.expanduser("~/Documents/plot_map.sh"),
            "Bash Script (*.sh);;All Files (*)"
        )
        if not path:
            return

        try:
            script = self.engine.generate_script(active_tab.config)
            with open(path, "w", encoding="utf-8") as f:
                f.write(script)
            os.chmod(path, 0o755)
            QtWidgets.QMessageBox.information(self, "Script Exported", f"GMT script saved to:\n{path}")
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Export Failed", f"Failed to export script:\n{e}")

    def show_script_viewer(self) -> None:
        """Displays interactive dialog allowing preview, editing, synchronization, and direct execution of GMT script."""
        active_tab = self.get_active_tab_view()
        if not self.engine or not active_tab or not active_tab.config:
            QtWidgets.QMessageBox.warning(self, "Notice", "No active plot.")
            return

        try:
            script = self.engine.generate_script(active_tab.config)
        except (ValueError, RuntimeError) as exc:
            QtWidgets.QMessageBox.warning(self, "Cannot generate script", str(exc))
            return
        dlg = ScriptEditorDialog(script, active_tab.config, self.engine, self)
        if dlg.exec() == QtWidgets.QDialog.DialogCode.Accepted:
            if dlg.custom_render_path:
                # Custom bash execution produced an image
                active_tab.set_map_image(dlg.custom_render_path, dlg.applied_config or active_tab.config, self.engine)
                if dlg.applied_config:
                    self.control_panel.sync_from_config(dlg.applied_config)
                self.status_lbl_time.setText("Executed custom GMT script successfully.")
            elif dlg.applied_config:
                # Synced back into GUI and rendered
                self.control_panel.sync_from_config(dlg.applied_config)
                self._render_tab(active_tab, dlg.applied_config)
                self.status_lbl_time.setText("Synchronized script modifications to GUI.")

    def _show_about(self) -> None:
        gmt_ver = self.engine.get_version() if self.engine else "Not found"
        QtWidgets.QMessageBox.about(
            self,
            "About Graticule",
            f"<h3>Graticule v0.4.0</h3>"
            f"<p>High-performance NetCDF viewer & plotter powered by GMT 6.</p>"
            f"<p>Inspired by NASA GISS Panoply. Independent open-source project (MIT License), not affiliated with NASA or the GMT team.</p>"
            f"<p><b>GMT Backend:</b> Version {gmt_ver}</p>"
            f"<p><b>GUI Framework:</b> PySide6 (Qt)</p>"
            f"<p>Features multi-tab comparison, LOD preview acceleration, and GMT Modern Mode script generation.</p>"
        )

    def closeEvent(self, event):
        if self._workers or getattr(self, "_range_workers", set()):
            self._closing = True
            self._pending.clear()
            for thread in self._workers.values(): thread.requestInterruption()
            self.status_lbl_time.setText("Finishing active GMT jobs before closing…")
            event.ignore()
            return
        self._render_owner.cleanup()
        if self.engine: self.engine.close()
        event.accept()
