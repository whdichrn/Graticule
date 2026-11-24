# Graticule

Native macOS SwiftUI and Python/GMT 6 viewer and publication-grade cartographic plotter for NetCDF, HDF, and GMT grid datasets.

## Highlights

- **Native macOS App (`macos/`)**: SwiftUI interface with Liquid Glass styling on macOS 26/27 SDK, multi-tab windows, live Inspector controls, interactive pan/zoom canvas, coordinate hover readout, Path Bar subregion history, and Quick Look-style dataset overview cards.
- **Large-Grid Performance**: Fast contiguous NetCDF Level-of-Detail (LOD) decimation handles multi-gigabyte global grids (such as GEBCO 15-arcsecond bathymetry) in seconds, while **Export Image** always renders from full-resolution source data at publication DPI (300+ DPI).
- **Interactive Subregion & Polar Presets**: Box-select geographic subregions (drill down in-tab with the Path Bar or open in a new native tab with `⌥`-drag) and jump to Arctic/Antarctic stereographic presets.
- **Reproducible GMT 6 Modern Mode Workflow**: Inspect, edit, synchronize, or export standalone `gmt` bash scripts at any time.
- **Optional GMT-China CN-Border Support**: Disabled by default; can be enabled in **Settings (`⌘,`) → General → Map Borders** with native `URLSession` download or offline ZIP import.
- **Headless CLI & Cross-Platform Qt Fallback**: Batch render maps, inspect variables, and generate standalone GMT scripts from the terminal or via the PySide6 desktop GUI.

## Requirements

- **GMT 6** and **Ghostscript** (`gmt`, `gs`) on `PATH` or inside your Python/conda/micromamba environment.
- **Python 3.9+** with `numpy`, `xarray`, `netCDF4` (plus `PySide6-Essentials` if using the Qt GUI, and `pdftocairo` from Poppler for SVG export).
- **macOS 13.0+ (Ventura and newer)** to run the native macOS app (`Graticule.app`), or Xcode / Swift 6 toolchain to build from source. Prebuilt releases bundle the Python backend inside `Graticule.app/Contents/Resources/backend`.

## Quick Start

### 1. Install the Python Backend & CLI

```bash
python -m pip install -e .
```

Use the CLI or legacy Qt UI:

```bash
# Print dataset metadata and variable list
graticule dataset.nc -i

# Render a publication PNG
graticule dataset.nc -v elevation -o map.png -J IntMollOcean -C turbo --mask land --dpi 300

# Render a regional plot with explicit -R and -T range
graticule dataset.nc -v temperature -o regional.pdf -R 110/125/18/30 -T -50/50

# Export a reproducible GMT Modern Mode script
graticule dataset.nc -v elevation -s > run_plot.sh
```

### 2. Build & Install Native macOS App (`Graticule.app`)

```bash
bash macos/scripts/build_app.sh --install
```

Optional `--set-default` registers `/Applications/Graticule.app` as the default handler for `.nc`, `.nc4`, `.cdf`, `.grd`, `.h5`, and `.hdf` files.

Environment overrides (optional, configurable in **Settings → Environment**):

- `GRATICULE_PYTHON`: path to Python interpreter with `numpy`, `xarray`, `netCDF4`
- `GMT_BIN`: path to `gmt` executable
- `GRATICULE_ROOT`: path to this repository root

## Running Tests

```bash
# Python backend, CLI, metadata, RPC server, and Qt tests
QT_QPA_PLATFORM=offscreen python -m pytest -q tests

# Swift package & live RPC integration tests
swift test --package-path macos
```

## License & Acknowledgments

Released under the **MIT License** — see [LICENSE](LICENSE).

**Acknowledgments & Disclaimer**: Graticule is inspired by **NASA GISS Panoply** and powered by **Generic Mapping Tools (GMT 6)**. Graticule is an independent open-source project and is not affiliated with, sponsored by, or endorsed by NASA or the GMT development team.
