"""
Command Line Interface (CLI) for Graticule.
Supports:
1. Headless batch rendering to image files (PNG, PDF, SVG, TIFF) via GMT 6.
2. Dataset metadata inspection (-i / --info).
3. Standalone GMT Modern Mode bash script generation (-s / --script-only).
4. Interactive GUI launching with dataset and variable pre-loaded.
All output, messages, and arguments are in English without emojis.
"""

import sys
import os
import time
import argparse
from pathlib import Path
from copy import copy
import math
from typing import Optional, Dict, Tuple, List

from .backend.nc_reader import NetCDFMetadataReader, DatasetMeta, VarMeta
from .backend.gmt_engine import GMTEngine, PlotConfig


def parse_region_string(r_str: str) -> Tuple[float, float, float, float]:
    """
    Parses a region string in west/east/south/north format.
    Accepts e.g. '110/125/18/30' or '-R110/125/18/30'.
    """
    cleaned = r_str.strip()
    if cleaned.startswith("-R"):
        cleaned = cleaned[2:]
    parts = cleaned.split("/")
    if len(parts) != 4:
        raise ValueError(f"Invalid region format: '{r_str}'. Expected 'west/east/south/north'.")
    region = tuple(map(float, parts))
    if not all(math.isfinite(v) for v in region) or region[0] >= region[1] or region[2] >= region[3]:
        raise ValueError("Region requires finite west < east and south < north.")
    return region


def parse_range_string(t_str: str) -> Tuple[float, float]:
    """
    Parses a value range in min/max format.
    Accepts e.g. '-50/50' or '-T-50/50'.
    """
    cleaned = t_str.strip()
    if cleaned.startswith("-T"):
        cleaned = cleaned[2:]
    parts = cleaned.split("/")
    if len(parts) != 2:
        raise ValueError(f"Invalid range format: '{t_str}'. Expected 'min/max'.")
    values = tuple(map(float, parts))
    if not all(math.isfinite(v) for v in values) or values[0] >= values[1]:
        raise ValueError("Color range requires finite minimum < maximum.")
    return values


def parse_slice_string(slice_str: str) -> Dict[str, int]:
    """
    Parses dimension slices formatted as 'dim1=idx1,dim2=idx2'.
    """
    slices: Dict[str, int] = {}
    if not slice_str:
        return slices
    for item in slice_str.split(","):
        item = item.strip()
        if "=" not in item:
            raise ValueError(f"Invalid slice: {item}. Use dim=index.")
        dim, idx = item.split("=", 1)
        if not dim.strip() or dim.strip() in slices: raise ValueError(f"Empty or duplicate slice dimension: {dim}")
        slices[dim.strip()] = int(idx.strip())
    return slices


def print_dataset_info(meta: DatasetMeta) -> None:
    """Prints formatted dataset metadata to stdout."""
    print("=" * 72)
    print(f"Dataset File: {meta.file_path}")
    print(f"Variables:    {len(meta.variables)} total ({sum(1 for v in meta.variables.values() if v.is_2d_plotable)} plottable)")
    print("=" * 72)

    print("\nDimensions:")
    for dim_name, size in meta.dimensions.items():
        coord_sample = ""
        if dim_name in meta.dimension_coords:
            c = meta.dimension_coords[dim_name]
            if len(c) > 0:
                coord_sample = f" [from {c[0]} to {c[-1]}]"
        print(f"  - {dim_name:<16}: {size:>8}{coord_sample}")

    print("\nVariables (2D plottable marked with *):")
    for var_name, var in meta.variables.items():
        star = "* " if var.is_2d_plotable else "  "
        dims_str = f"({', '.join(var.dimensions)})"
        shape_str = f"{var.shape}"
        units_str = f" [{var.attrs.get('units', '')}]" if "units" in var.attrs else ""
        print(f" {star}{var_name:<20} {dims_str:<24} {shape_str:<16} {var.dtype}{units_str}")

    if meta.global_attrs:
        print("\nGlobal Attributes:")
        for k, v in list(meta.global_attrs.items())[:15]:
            v_str = str(v)
            if len(v_str) > 60:
                v_str = v_str[:57] + "..."
            print(f"  - {k:<20}: {v_str}")
        if len(meta.global_attrs) > 15:
            print(f"  ... ({len(meta.global_attrs) - 15} more attributes)")
    print("=" * 72)


def run_headless_plot(args, meta: DatasetMeta, engine: GMTEngine) -> int:
    """Executes headless terminal plot generation or script export."""
    # 1. Determine target variable
    var_name = args.variable
    if not var_name:
        # Pick the first 2D plottable variable
        for v in meta.variables.values():
            if v.is_2d_plotable:
                var_name = v.name
                break

    if not var_name or var_name not in meta.variables:
        print(f"Error: Variable '{var_name}' not found in dataset.", file=sys.stderr)
        print("Available variables:", file=sys.stderr)
        for v in meta.variables.values():
            if v.is_2d_plotable:
                print(f"  - {v.name}", file=sys.stderr)
        return 1

    var = meta.variables[var_name]

    if not var.is_2d_plotable:
        raise ValueError(var.unsupported_reason or "Variable is not a numeric 2D grid.")

    # 2. Slice indices
    slice_indices = parse_slice_string(args.slice) if args.slice else {}
    grid_spec = NetCDFMetadataReader.build_gmt_grid_spec(meta.file_path, var, slice_indices)

    # 3. Determine region
    region: Optional[Tuple[float, float, float, float]] = None
    if args.region:
        region = parse_region_string(args.region)
    elif var.x_range and var.y_range:
        region = (var.x_range[0], var.x_range[1], var.y_range[0], var.y_range[1])

    # 4. Determine projection
    projection = args.projection
    if not projection:
        # Use intelligent projection recommender
        projs = GMTEngine.get_recommended_projections(region, var.name, var.attrs)
        projection = projs[0][1] if var.is_geographic else "X16c/10c"

    # 5. Determine CPT & range
    cpt = args.cpt
    if not cpt:
        # Default based on variable semantics
        var_lower = var.name.lower()
        if any(k in var_lower for k in ("txx", "tyy", "tzz", "txy", "txz", "tyz", "anom", "dov")):
            cpt = "polar"
        elif any(k in var_lower for k in ("elev", "dem", "topo", "altitude")):
            cpt = "relief"
        elif any(k in var_lower for k in ("bathymetry", "bathy", "depth")):
            cpt = "ocean"
        else:
            cpt = "turbo"

    cpt_range: Optional[Tuple[float, float]] = None
    if args.range:
        cpt_range = parse_range_string(args.range)
    else:
        # Auto-scan range
        mask_mode = args.mask or "none"
        info = engine.get_masked_grid_info(grid_spec, region, mask_mode)
        if info:
            zmin = info.get("z_min", 0.0)
            zmax = info.get("z_max", 0.0)
            if args.symmetric_range or any(k in var.name.lower() for k in ("txx", "tyy", "tzz", "txy", "txz", "tyz", "anom", "dov")):
                max_abs = max(abs(zmin), abs(zmax))
                cpt_range = (-max_abs, max_abs)
            elif zmin != zmax:
                cpt_range = (zmin, zmax)
            else:
                cpt_range = (zmin - 1.0, zmax + 1.0)

    # 6. Title and units
    title = args.title if args.title is not None else var.display_title.strip('"\'')
    unit = var.attrs.get("units", "")

    # 7. Assemble PlotConfig
    config = PlotConfig(
        grid_spec=grid_spec,
        region=region,
        projection=projection,
        cpt=cpt,
        cpt_range=cpt_range,
        cpt_reverse=args.reverse_cpt,
        cpt_continuous=not args.discrete,
        mask_mode=args.mask or "none",
        mask_color=args.mask_color,
        source_path=meta.file_path, variable_name=var.name, slice_indices=slice_indices,
        is_geographic=var.is_geographic,
        variable_description=" ".join(str(var.attrs.get(k, "")) for k in ("standard_name", "long_name", "units", "comment", "description")).strip(),
        projection_mode="manual" if args.projection else "auto",
        show_frame=not args.no_frame, frame_sides=args.frame_sides,
        x_interval=args.x_interval, y_interval=args.y_interval,
        title_size=args.title_size, annotation_size=args.annotation_size, label_size=args.label_size,
        symmetric_cpt=args.symmetric_range, cpt_levels=args.levels, coast_resolution=args.coast_resolution, coast_pen=args.coast_pen,
        interpolation=args.interpolation, nan_color=args.nan_color, preview=args.preview,
        makecpt_args=args.makecpt_args, coast_args=args.coast_args, colorbar_args=args.colorbar_args,
        show_coast=not args.no_coast,
        show_borders=args.borders,
        show_grid=not args.no_grid,
        show_colorbar=not args.no_colorbar,
        colorbar_title=args.colorbar_label if args.colorbar_label is not None else unit,
        dpi=args.dpi,
        title=title,
        extra_args=args.extra_args or "",
        gmt_conf=args.gmt_conf or ""
    )

    config.validate()

    # Mode A: Standalone Script Export
    if args.script_only:
        script_target = str(Path(args.output).with_suffix(".png")) if args.output and args.output.lower().endswith(".sh") else args.output or "plot.png"
        script = engine.generate_script(config, script_target)
        if args.output and not args.output.lower().endswith((".png", ".jpg", ".jpeg", ".pdf", ".svg", ".tif")):
            # Output is a script filename
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(script)
            print(f"GMT script saved to: {args.output}")
        else:
            print(script)
        return 0

    # Mode B: Headless Render
    if not args.output:
        args.output = f"{var.name}.png"

    print(f"Rendering variable '{var.name}'...")
    print(f"  Projection: -J{config.projection}")
    if config.region:
        w, e, s, n = config.region
        print(f"  Region:     -R{w:.4f}/{e:.4f}/{s:.4f}/{n:.4f}")
    print(f"  Colormap:   -C{config.cpt} (Range: {config.cpt_range})")
    print(f"  Output:     {args.output} (DPI: {config.dpi})")

    t0 = time.perf_counter()
    try:
        engine.render(config, args.output)
        elapsed = time.perf_counter() - t0
        file_size_kb = os.path.getsize(args.output) / 1024.0 if os.path.exists(args.output) else 0
        print(f"Successfully generated: {args.output} ({file_size_kb:.1f} KB in {elapsed:.2f} s)")
        return 0
    except Exception as e:
        print(f"Rendering Error:\n{e}", file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    """Constructs the argument parser for the CLI."""
    parser = argparse.ArgumentParser(
        prog="graticule",
        description="Graticule: Fast NetCDF Viewer & Cartographic Plotter powered by GMT 6",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Inspect NetCDF dataset structure headlessly:
  graticule dataset.nc
  graticule dataset.nc -i

  # Render high-resolution PNG image headlessly:
  graticule dataset.nc -v Txx -o map.png -J IntMollOcean -C turbo --mask land --dpi 300

  # Render regional Lambert Conformal Conic plot:
  graticule dataset.nc -v Txx -o regional.pdf -R 110/125/18/30 -T -50/50

  # Output standalone reproducible GMT Modern Mode bash script:
  graticule dataset.nc -v Txx -s > run_plot.sh
        """
    )

    parser.add_argument("file", nargs="*", help="One or more NetCDF / HDF / GMT grid files")
    parser.add_argument("-v", "--variable", default=None, help="Variable name to plot")
    parser.add_argument("-i", "--info", action="store_true", help="Print dataset metadata and variable information")
    parser.add_argument("-o", "--output", default=None, help="Output image file path (.png, .pdf, .svg, .tif)")
    parser.add_argument("-s", "--script-only", action="store_true", help="Generate standalone GMT bash script instead of image")

    # Cartographic Parameters
    parser.add_argument("-R", "--region", default=None, help="Bounding box: west/east/south/north (e.g. 110/125/18/30)")
    parser.add_argument("-J", "--projection", default=None, help="GMT projection code or 'IntMollOcean' (e.g. Q16c, M16c, IntMollOcean)")
    parser.add_argument("-C", "--cpt", default=None, help="Colormap palette name (e.g. turbo, rainbow, polar, seis, batlow)")
    parser.add_argument("-T", "--range", default=None, help="Data range: min/max (e.g. -50/50)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("-Z", "--continuous", action="store_true", default=True, help="Continuous CPT (default; GMT makecpt -Z)")
    mode.add_argument("--discrete", action="store_true", help="Discrete CPT using --levels intervals")
    parser.add_argument("--symmetric-range", action="store_true", help="Center automatically scanned CPT range on zero")
    parser.add_argument("--levels", type=int, default=16, help="Number of discrete color intervals (default 16)")
    parser.add_argument("-I", "--reverse-cpt", action="store_true", help="Invert colormap palette (-I)")

    # Overlays & Masking
    parser.add_argument("--mask", choices=["none", "land", "ocean"], default="none", help="Masking mode: 'none', 'land' (ocean data only), or 'ocean' (land data only)")
    parser.add_argument("--no-coast", action="store_true", help="Do not draw coastlines")
    parser.add_argument("--borders", action="store_true", help="Draw political country borders")
    parser.add_argument("--no-grid", action="store_true", help="Hide gridlines; retain frame and tick labels")
    parser.add_argument("--no-colorbar", action="store_true", help="Do not draw colorbar")

    # Layout & Output
    parser.add_argument("--title", default=None, help="Custom map title")
    parser.add_argument("--dpi", type=int, default=300, help="Output image resolution in DPI (default: 300)")
    parser.add_argument("--slice", default=None, help="Extra dimension slices: dim1=idx1,dim2=idx2")
    parser.add_argument("--extra-args", default="", help="Extra GMT command-line flags (e.g. -W0.5p,blue -BWSen)")
    parser.add_argument("--gmt-conf", default="", help="Extra gmt.conf key=val settings (e.g. MAP_FRAME_TYPE=plain)")
    parser.add_argument("--no-frame", action="store_true", help="Hide map frame and tick labels")
    parser.add_argument("--frame-sides", default="WSen", help="GMT frame sides (default WSen)")
    parser.add_argument("--x-interval", type=float, default=0, help="X annotation/grid interval; 0=auto")
    parser.add_argument("--y-interval", type=float, default=0, help="Y annotation/grid interval; 0=auto")
    parser.add_argument("--title-size", type=float, default=14, help="Title font size in points")
    parser.add_argument("--annotation-size", type=float, default=10, help="Tick label font size in points")
    parser.add_argument("--label-size", type=float, default=11, help="Axis label font size in points")
    parser.add_argument("--colorbar-label", default=None, help="Colorbar label (default variable units)")
    parser.add_argument("--mask-color", default="gray90", help="Land/ocean mask fill")
    parser.add_argument("--nan-color", default="gray90", help="Missing data color")
    parser.add_argument("--coast-resolution", choices=list("clihfa"), default="l", help="Coastline resolution")
    parser.add_argument("--coast-pen", default="0.4p,gray25", help="GMT coastline pen")
    parser.add_argument("--interpolation", choices=list("nlcb"), default="c", help="Nearest, linear, cubic, B-spline")
    parser.add_argument("--preview", action="store_true", help="Use reduced resolution for large grids; default uses full data")
    parser.add_argument("--makecpt-args", default="", help="Extra makecpt module arguments")
    parser.add_argument("--coast-args", default="", help="Extra coast module arguments")
    parser.add_argument("--colorbar-args", default="", help="Extra colorbar module arguments")

    return parser


def preprocess_args(argv: List[str]) -> List[str]:
    """Preprocesses command line args to handle negative numbers in -T and -R flags."""
    new_args: List[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-T", "--range", "-R", "--region", "--extra-args", "--makecpt-args", "--coast-args", "--colorbar-args") and i + 1 < len(argv):
            next_arg = argv[i + 1]
            if next_arg.startswith("-"):
                new_args.append(f"{arg}={next_arg}")
                i += 2
                continue
        new_args.append(arg)
        i += 1
    return new_args


def main() -> int:
    """CLI Entry Point."""
    parser = build_parser()
    clean_argv = preprocess_args(sys.argv[1:])
    args = parser.parse_args(clean_argv)

    headless = args.output or args.info or args.script_only
    if not args.file:
        if headless: parser.error("Headless operations require at least one dataset.")
        parser.print_help()
        return 0
    if not headless:
        args.info = True
    if len(args.file) > 1 and not args.info:
        if not args.output or Path(args.output).suffix:
            parser.error("For multiple datasets, --output must be a directory (for example --output results/).")
        stems = [Path(f).stem for f in args.file]
        if len(set(stems)) != len(stems): parser.error("Batch inputs need distinct filenames to avoid output collisions.")
        Path(args.output).mkdir(parents=True, exist_ok=True)
    engine = None
    failed = False
    try:
        if not args.info: engine = GMTEngine()
        for path in args.file:
            try:
                meta = NetCDFMetadataReader.open(path)
                if args.info:
                    print_dataset_info(meta)
                    continue
                options = copy(args)
                if len(args.file) > 1:
                    options.output = str(Path(args.output)/(Path(path).stem+(".sh" if args.script_only else ".png")))
                failed = bool(run_headless_plot(options, meta, engine)) or failed
            except (OSError, ValueError, RuntimeError) as exc:
                print(f"Error for {path}: {exc}", file=sys.stderr)
                failed = True
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    finally:
        if engine: engine.close()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
