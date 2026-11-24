"""
Dataset Tree Explorer.
Displays NetCDF hierarchy, dimensions, variables, attributes, and search filters.
Provides safe single-click inspection and double-click / button activation to prevent UI hangs.
All labels, tooltips, and text are in English without emojis.
"""

from typing import Optional, Dict
from PySide6 import QtCore, QtGui, QtWidgets
from ..backend.nc_reader import DatasetMeta, VarMeta


class DatasetTreeWidget(QtWidgets.QWidget):
    """Explorer widget for browsing NetCDF dataset structure and selecting variables."""

    dataset_selected = QtCore.Signal(object)
    dataset_close_requested = QtCore.Signal(object)
    variable_selected = QtCore.Signal(object)    # Emits VarMeta on single click (inspect only)
    variable_activated = QtCore.Signal(object)   # Emits VarMeta on double-click / Plot button
    plot_in_new_tab = QtCore.Signal(object)      # Emits VarMeta to plot in a brand new tab

    def __init__(self, parent=None):
        super().__init__(parent)
        self._dataset_meta: Optional[DatasetMeta] = None
        self._current_var: Optional[VarMeta] = None
        self._roots = {}
        self._setup_ui()

    def _setup_ui(self) -> None:
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(6)

        # Search filter bar
        self.search_box = QtWidgets.QLineEdit()
        self.search_box.setPlaceholderText("Filter variables...")
        self.search_box.setClearButtonEnabled(True)
        self.search_box.textChanged.connect(self._filter_variables)
        layout.addWidget(self.search_box)

        # Tree widget
        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderLabels(["Dataset Structure", "Info"])
        self.tree.setColumnWidth(0, 180)
        self.tree.setAlternatingRowColors(True)
        self.tree.itemSelectionChanged.connect(self._on_item_selection_changed)
        self.tree.itemDoubleClicked.connect(self._on_item_double_clicked)
        self.tree.setContextMenuPolicy(QtCore.Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._context_menu)
        layout.addWidget(self.tree, stretch=2)

        # Action Buttons
        btn_layout = QtWidgets.QHBoxLayout()
        self.btn_plot = QtWidgets.QPushButton("Plot Variable")
        self.btn_plot.setToolTip("Plot selected 2D variable in active tab (or double-click the variable)")
        self.btn_plot.setStyleSheet("font-weight: bold; padding: 4px;")
        self.btn_plot.setEnabled(False)
        self.btn_plot.clicked.connect(self._on_plot_clicked)

        self.btn_plot_new_tab = QtWidgets.QPushButton("Plot in New Tab")
        self.btn_plot_new_tab.setToolTip("Plot this variable in a new tab, keeping existing plots open")
        self.btn_plot_new_tab.setEnabled(False)
        self.btn_plot_new_tab.clicked.connect(self._on_plot_new_tab_clicked)

        btn_layout.addWidget(self.btn_plot)
        btn_layout.addWidget(self.btn_plot_new_tab)
        layout.addLayout(btn_layout)

        # Properties Inspector Group
        prop_group = QtWidgets.QGroupBox("Attributes & Details")
        prop_layout = QtWidgets.QVBoxLayout(prop_group)
        prop_layout.setContentsMargins(4, 4, 4, 4)

        self.prop_table = QtWidgets.QTableWidget()
        self.prop_table.setColumnCount(2)
        self.prop_table.setHorizontalHeaderLabels(["Property", "Value"])
        self.prop_table.horizontalHeader().setStretchLastSection(True)
        self.prop_table.verticalHeader().setVisible(False)
        self.prop_table.setAlternatingRowColors(True)
        prop_layout.addWidget(self.prop_table)

        layout.addWidget(prop_group, stretch=1)

    def load_dataset(self, meta: DatasetMeta) -> None:
        """Populates the tree with the dataset metadata."""
        self._dataset_meta = meta
        if meta.file_path in self._roots:
            self.select_variable(meta.file_path, next(iter(meta.variables), ""))
            return
        self.prop_table.setRowCount(0)
        self._current_var = None
        self.btn_plot.setEnabled(False)
        self.btn_plot_new_tab.setEnabled(False)

        # Root file node
        root_node = QtWidgets.QTreeWidgetItem(self.tree, [
            QtCore.QFileInfo(meta.file_path).fileName(),
            f"{len(meta.variables)} variables"
        ])
        self._roots[meta.file_path] = root_node
        root_node.setData(0, QtCore.Qt.ItemDataRole.UserRole+1, meta)
        root_node.setToolTip(0, meta.file_path)
        root_font = root_node.font(0)
        root_font.setBold(True)
        root_node.setFont(0, root_font)

        # Dimensions node
        dim_node = QtWidgets.QTreeWidgetItem(root_node, ["Dimensions", f"{len(meta.dimensions)}"])
        for d_name, d_size in meta.dimensions.items():
            QtWidgets.QTreeWidgetItem(dim_node, [d_name, str(d_size)])

        # 2D+ Plotable Grids node
        plotable_node = QtWidgets.QTreeWidgetItem(root_node, ["Plotable Grids (2D+)", ""])
        plotable_node.setExpanded(True)
        font = plotable_node.font(0)
        font.setBold(True)
        plotable_node.setFont(0, font)

        # Other 1D variables
        other_node = QtWidgets.QTreeWidgetItem(root_node, ["1D / Non-grid Variables", ""])

        first_plotable_item = None

        for var_name, var in meta.variables.items():
            shape_str = " x ".join(str(s) for s in var.shape)
            units = var.attrs.get("units", "")
            target_parent = plotable_node if var.is_2d_plotable else other_node

            item = QtWidgets.QTreeWidgetItem(target_parent, [var_name, f"[{shape_str}] {units}"])
            item.setData(0, QtCore.Qt.ItemDataRole.UserRole, var)
            item.setToolTip(0, var.unsupported_reason or var.display_title)

            if var.is_2d_plotable and first_plotable_item is None:
                first_plotable_item = item

        # Global Attributes node
        attr_node = QtWidgets.QTreeWidgetItem(root_node, ["Global Attributes", f"{len(meta.global_attrs)}"])
        for k, v in meta.global_attrs.items():
            str_v = str(v)
            if len(str_v) > 60:
                str_v = str_v[:57] + "..."
            QtWidgets.QTreeWidgetItem(attr_node, [str(k), str_v])

        root_node.setExpanded(True)

        # Auto-select first plotable item without triggering a heavy render
        if first_plotable_item:
            self.tree.blockSignals(True)
            self.tree.setCurrentItem(first_plotable_item)
            self.tree.blockSignals(False)
            self._on_item_selection_changed()

    def _on_item_selection_changed(self) -> None:
        """Handles selection of a tree item (inspection only)."""
        items = self.tree.selectedItems()
        if not items:
            self.btn_plot.setEnabled(False)
            self.btn_plot_new_tab.setEnabled(False)
            return

        item = items[0]
        root = item
        while root.parent(): root = root.parent()
        meta = root.data(0, QtCore.Qt.ItemDataRole.UserRole+1)
        if meta:
            self._dataset_meta = meta
            self.dataset_selected.emit(meta)
        var: Optional[VarMeta] = item.data(0, QtCore.Qt.ItemDataRole.UserRole)
        self._current_var = var

        # Populate property table
        self.prop_table.setRowCount(0)
        if var:
            self.btn_plot.setEnabled(var.is_2d_plotable)
            self.btn_plot_new_tab.setEnabled(var.is_2d_plotable)

            props = [
                ("Name", var.name),
                ("Dimensions", ", ".join(var.dimensions)),
                ("Shape", str(var.shape)),
                ("Data Type", var.dtype),
                ("Plotable", "Yes (2D Grid)" if var.is_2d_plotable else "No"),
                ("X Dimension", str(var.x_dim)),
                ("Y Dimension", str(var.y_dim)),
                ("Slice Dims", ", ".join(var.slice_dims) if var.slice_dims else "None"),
            ]
            if var.x_range:
                props.append(("X Range", f"[{var.x_range[0]:.4f}, {var.x_range[1]:.4f}]"))
            if var.y_range:
                props.append(("Y Range", f"[{var.y_range[0]:.4f}, {var.y_range[1]:.4f}]"))
            if var.v_range:
                props.append(("Value Range", f"[{var.v_range[0]:.4f}, {var.v_range[1]:.4f}]"))

            for attr_k, attr_v in var.attrs.items():
                props.append((f"attr:{attr_k}", str(attr_v)))

            self.prop_table.setRowCount(len(props))
            for row, (k, v) in enumerate(props):
                item_k = QtWidgets.QTableWidgetItem(k)
                item_v = QtWidgets.QTableWidgetItem(v)
                item_k.setFlags(item_k.flags() ^ QtCore.Qt.ItemFlag.ItemIsEditable)
                item_v.setFlags(item_v.flags() ^ QtCore.Qt.ItemFlag.ItemIsEditable)
                self.prop_table.setItem(row, 0, item_k)
                self.prop_table.setItem(row, 1, item_v)

            self.variable_selected.emit(var)
        else:
            self.btn_plot.setEnabled(False)
            self.btn_plot_new_tab.setEnabled(False)

    def _on_item_double_clicked(self, item: QtWidgets.QTreeWidgetItem, column: int) -> None:
        """Double clicking a plotable variable activates it and triggers plot."""
        var: Optional[VarMeta] = item.data(0, QtCore.Qt.ItemDataRole.UserRole)
        if var and var.is_2d_plotable:
            self.variable_activated.emit(var)

    def _on_plot_clicked(self) -> None:
        if self._current_var and self._current_var.is_2d_plotable:
            self.variable_activated.emit(self._current_var)

    def _on_plot_new_tab_clicked(self) -> None:
        if self._current_var and self._current_var.is_2d_plotable:
            self.plot_in_new_tab.emit(self._current_var)

    def select_variable(self, path, name):
        root = self._roots.get(path)
        if not root: return
        iterator = QtWidgets.QTreeWidgetItemIterator(root)
        while iterator.value():
            item = iterator.value()
            var = item.data(0, QtCore.Qt.ItemDataRole.UserRole)
            if var and var.name == name:
                blocker = QtCore.QSignalBlocker(self.tree)
                self.tree.setCurrentItem(item)
                self._current_var = var
                self._dataset_meta = root.data(0, QtCore.Qt.ItemDataRole.UserRole+1)
                self._on_item_selection_changed()
                return
            iterator += 1

    def remove_dataset(self, path):
        root = self._roots.pop(path, None)
        if root:
            self.tree.takeTopLevelItem(self.tree.indexOfTopLevelItem(root))
        if self._dataset_meta and self._dataset_meta.file_path == path:
            self._dataset_meta = self._current_var = None
            self.btn_plot.setEnabled(False); self.btn_plot_new_tab.setEnabled(False)
            self.prop_table.setRowCount(0)

    def _context_menu(self, position):
        item = self.tree.itemAt(position)
        if not item: return
        while item.parent(): item = item.parent()
        meta = item.data(0, QtCore.Qt.ItemDataRole.UserRole+1)
        if not meta: return
        menu = QtWidgets.QMenu(self)
        action = menu.addAction("Close dataset and its plots")
        if menu.exec(self.tree.viewport().mapToGlobal(position)) == action:
            self.dataset_close_requested.emit(meta)

    def _filter_variables(self, query: str) -> None:
        """Filters variable items in tree based on search text."""
        query = query.strip().lower()

        def filter_item(item: QtWidgets.QTreeWidgetItem) -> bool:
            has_matching_child = False
            for i in range(item.childCount()):
                child_matches = filter_item(item.child(i))
                if child_matches:
                    has_matching_child = True

            text_match = query in item.text(0).lower() or query in item.text(1).lower()
            is_visible = (query == "") or text_match or has_matching_child
            item.setHidden(not is_visible)
            if query and is_visible:
                item.setExpanded(True)
            return is_visible

        for i in range(self.tree.topLevelItemCount()):
            filter_item(self.tree.topLevelItem(i))
