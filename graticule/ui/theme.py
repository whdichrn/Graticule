"""
Theme & Styling for Graticule.
Provides a modern, refined user interface with macOS adaptations:
- Unified title and toolbar appearance
- Clean typography (SF Pro / System Font)
- Subtle borders and light neutral palette
- Rounded inputs and modern button states
- Minimalist macOS scrollbars and clean tab widgets
All labels and styling are in English without emojis.
"""

import sys
from PySide6 import QtWidgets, QtGui, QtCore


def get_modern_stylesheet() -> str:
    """Returns the unified modern stylesheet."""
    return """
    /* Global Base */
    QWidget {
        font-size: 12px;
        color: #1f2328;
    }

    QMainWindow {
        background-color: #f6f8fa;
    }

    /* QSplitter */
    QSplitter::handle {
        background-color: #e1e4e8;
    }
    QSplitter::handle:horizontal {
        width: 1px;
    }
    QSplitter::handle:vertical {
        height: 1px;
    }

    /* Group Boxes */
    QGroupBox {
        font-weight: 600;
        font-size: 11px;
        border: 1px solid #e1e4e8;
        border-radius: 6px;
        margin-top: 14px;
        padding-top: 12px;
        padding-bottom: 8px;
        padding-left: 8px;
        padding-right: 8px;
        background-color: #ffffff;
    }
    QGroupBox::title {
        subcontrol-origin: margin;
        subcontrol-position: top left;
        left: 10px;
        padding: 0 4px;
        color: #24292f;
        background-color: #ffffff;
    }

    /* Buttons */
    QPushButton {
        background-color: #f6f8fa;
        color: #24292f;
        border: 1px solid #d0d7de;
        border-radius: 5px;
        padding: 5px 12px;
        font-size: 12px;
        font-weight: 500;
    }
    QPushButton:hover {
        background-color: #eaeef2;
        border-color: #afb8c1;
    }
    QPushButton:pressed {
        background-color: #ebecf0;
        border-color: #8c959f;
    }
    QPushButton:disabled {
        background-color: #f6f8fa;
        color: #8c959f;
        border-color: #e1e4e8;
    }

    /* Primary Apply Button */
    QPushButton#btn_apply, QPushButton[primary="true"] {
        background-color: #0969da;
        color: #ffffff;
        font-weight: 600;
        font-size: 13px;
        padding: 8px 16px;
        border: 1px solid #0854ad;
        border-radius: 6px;
    }
    QPushButton#btn_apply:hover, QPushButton[primary="true"]:hover {
        background-color: #0854ad;
        border-color: #07458d;
    }
    QPushButton#btn_apply:pressed, QPushButton[primary="true"]:pressed {
        background-color: #07458d;
    }

    /* Inputs: LineEdit, SpinBoxes, ComboBox */
    QLineEdit, QSpinBox, QDoubleSpinBox, QComboBox {
        background-color: #ffffff;
        border: 1px solid #d0d7de;
        border-radius: 5px;
        padding: 4px 6px;
        font-size: 12px;
        color: #1f2328;
        min-height: 20px;
    }
    QLineEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus, QComboBox:focus {
        border: 1px solid #0969da;
        background-color: #ffffff;
    }
    QComboBox::drop-down {
        subcontrol-origin: padding;
        subcontrol-position: top right;
        width: 18px;
        border-left-width: 0px;
    }
    QComboBox QAbstractItemView {
        background-color: #ffffff;
        border: 1px solid #d0d7de;
        border-radius: 4px;
        selection-background-color: #0969da;
        selection-color: #ffffff;
        padding: 2px;
    }

    /* Tabs */
    QTabWidget, QSplitter { background-color: #f6f8fa; }
    QTabWidget::pane {
        border: 1px solid #e1e4e8;
        background-color: #ffffff;
        border-radius: 6px;
        top: -1px;
    }
    QTabBar { background-color: #f6f8fa; }
    QTabBar::tab {
        background-color: #f6f8fa;
        color: #656d76;
        border: 1px solid #e1e4e8;
        border-bottom: none;
        border-top-left-radius: 6px;
        border-top-right-radius: 6px;
        padding: 6px 14px;
        margin-right: 2px;
        font-size: 12px;
        font-weight: 500;
    }
    QTabBar::tab:selected {
        background-color: #ffffff;
        color: #0969da;
        font-weight: 600;
        border: 1px solid #e1e4e8;
        border-bottom: 2px solid #0969da;
    }
    QTabBar::tab:hover:!selected {
        background-color: #eaeef2;
        color: #1f2328;
    }
    /* Toolbars */
    QToolBar {
        background-color: #ffffff;
        border-bottom: 1px solid #e1e4e8;
        spacing: 4px;
        padding: 4px 6px;
    }
    QToolButton {
        background-color: transparent;
        border: 1px solid transparent;
        border-radius: 4px;
        padding: 4px 8px;
        font-size: 12px;
        font-weight: 500;
        color: #24292f;
    }
    QToolButton:hover {
        background-color: #f3f4f6;
        border-color: #d0d7de;
    }
    QToolButton:pressed {
        background-color: #eaeef2;
    }
    QToolButton:checked {
        background-color: #e1effe;
        border: 1px solid #76a9fa;
        color: #1a56db;
    }

    /* Tree View */
    QTreeWidget, QTreeView {
        border: 1px solid #e1e4e8;
        border-radius: 4px;
        background-color: #ffffff;
        alternate-background-color: #f8f9fa;
        show-decoration-selected: 1;
    }
    QTreeWidget::item {
        padding: 4px 6px;
    }
    QTreeWidget::item:hover {
        background-color: #f3f4f6;
    }
    QTreeWidget::item:selected {
        background-color: #e7f3ff;
        color: #0969da;
    }
    QHeaderView::section {
        background-color: #f6f8fa;
        border: none;
        border-bottom: 1px solid #d0d7de;
        border-right: 1px solid #e1e4e8;
        padding: 4px 8px;
        font-size: 11px;
        font-weight: 600;
        color: #57606a;
    }

    /* Scrollbars (Modern Minimalist macOS Style) */
    QScrollBar:vertical {
        width: 8px;
        background: transparent;
        margin: 0px;
    }
    QScrollBar::handle:vertical {
        background: #cbd5e1;
        border-radius: 4px;
        min-height: 24px;
    }
    QScrollBar::handle:vertical:hover {
        background: #94a3b8;
    }
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
        height: 0px;
    }
    QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
        background: transparent;
    }

    QScrollBar:horizontal {
        height: 8px;
        background: transparent;
        margin: 0px;
    }
    QScrollBar::handle:horizontal {
        background: #cbd5e1;
        border-radius: 4px;
        min-width: 24px;
    }
    QScrollBar::handle:horizontal:hover {
        background: #94a3b8;
    }
    QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
        width: 0px;
    }
    QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {
        background: transparent;
    }

    /* Slider Controls */
    QSlider::groove:horizontal {
        height: 4px;
        background: #e1e4e8;
        border-radius: 2px;
    }
    QSlider::sub-page:horizontal {
        background: #0969da;
        border-radius: 2px;
    }
    QSlider::handle:horizontal {
        width: 14px;
        height: 14px;
        margin: -5px 0;
        border-radius: 7px;
        background: #ffffff;
        border: 2px solid #0969da;
    }
    QSlider::handle:horizontal:hover {
        border-color: #0854ad;
    }

    /* CheckBoxes */
    QCheckBox {
        spacing: 6px;
        font-size: 12px;
        color: #24292f;
    }
    /* Status Bar */
    QStatusBar {
        border-top: 1px solid #e1e4e8;
        background-color: #f8f9fa;
        color: #57606a;
        font-size: 11px;
        padding: 2px 8px;
    }
    QStatusBar QLabel {
        padding: 0 6px;
    }

    /* Scroll Area */
    QScrollArea {
        border: none;
        background-color: transparent;
    }
    """


def apply_macos_theme(app: QtWidgets.QApplication, window: QtWidgets.QMainWindow) -> None:
    """Applies macOS native styling adjustments and modern stylesheet."""
    app.setStyle("Fusion")
    app.setFont(QtGui.QFont("Helvetica Neue" if sys.platform == "darwin" else "Arial", 11))
    app.setStyleSheet(get_modern_stylesheet())

    if sys.platform == "darwin":
        # Enable unified toolbar look on macOS
        try:
            window.setUnifiedTitleAndToolBarOnMac(True)
        except Exception:
            pass
