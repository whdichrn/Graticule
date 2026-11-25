"""
GMT Execution Engine.
Manages GMT Modern Mode commands, colormaps, high-speed rendering,
Level-of-Detail (LOD) downsampling for massive grids, and cartographic projections.
All labels, messages, and comments are in English.
"""

from dataclasses import dataclass, field, replace, asdict
from typing import Optional, Tuple, Dict, Any, List
import gc
import subprocess
import shutil
import tempfile
import os
import math
import hashlib
import json
import re
import shlex
import sys
import threading
from pathlib import Path
from collections import OrderedDict
import uuid
import numpy as np

from .npz_cache import resolve_nc_path


@dataclass
class PlotConfig:
    """Configuration for rendering a map/grid."""
    grid_spec: str
    region: Optional[Tuple[float, float, float, float]] = None  # (west, east, south, north)
    projection: str = "Q16c"  # Default: Equidistant Cylindrical (Plate Carree)
    cpt: str = "rainbow"      # Default: Classic Rainbow
    cpt_range: Optional[Tuple[float, float]] = None  # (zmin, zmax)
    cpt_reverse: bool = False
    cpt_continuous: bool = True
    mask_mode: str = "none"   # "none", "land", "ocean"
    mask_color: str = "gray90"
    show_coast: bool = True
    show_borders: bool = False
    show_grid: bool = True
    show_colorbar: bool = True
    colorbar_title: str = ""
    dpi: int = 150
    title: str = ""
    extra_args: str = ""      # Extra GMT command-line flags (e.g. -W0.5p,blue -BWSen)
    gmt_conf: str = ""        # Extra gmt.conf key=val settings (e.g. MAP_FRAME_TYPE=plain)

    projection_mode: str = "manual"  # auto recommendations or a fixed manual projection
    is_geographic: bool = True
    source_path: str = ""
    variable_name: str = ""
    variable_description: str = ""
    slice_indices: Dict[str, int] = field(default_factory=dict)
    show_frame: bool = True
    frame_sides: str = "WSen"
    x_interval: float = 0.0  # zero lets GMT choose
    y_interval: float = 0.0
    title_size: float = 14.0
    annotation_size: float = 10.0
    label_size: float = 11.0
    symmetric_cpt: bool = False
    cpt_levels: int = 16
    cpt_categorical: bool = False
    flag_values: Tuple[float, ...] = ()
    flag_meanings: Tuple[str, ...] = ()
    coast_resolution: str = "l"
    coast_pen: str = "0.4p,gray25"
    interpolation: str = "c"
    nan_color: str = "gray90"
    preview: bool = False
    makecpt_args: str = ""
    coast_args: str = ""
    colorbar_args: str = ""
    border_mode: str = "none"   # "none", "cn_l1", "cn_la", "gmt_global", "global_cn_l1", "global_cn_la"
    border_pen: str = "0.5p,gray25"
    cn_border_dir: str = ""

    def __post_init__(self):
        if self.region is not None: self.region = tuple(self.region)
        if self.cpt_range is not None: self.cpt_range = tuple(self.cpt_range)
        self.flag_values = tuple(float(x) for x in (self.flag_values or ()))
        self.flag_meanings = tuple(str(x) for x in (self.flag_meanings or ()))
        self.slice_indices = dict(self.slice_indices)
        if self.show_borders and self.border_mode == "none":
            self.border_mode = "gmt_global"
        elif self.border_mode in ("gmt_global", "global_cn_l1", "global_cn_la"):
            self.show_borders = True

    def validate(self) -> None:
        if not self.grid_spec:
            raise ValueError("Select a dataset and a numeric, regularly spaced grid variable.")
        if self.region:
            w, e, s, n = self.region
            if not all(math.isfinite(v) for v in self.region) or e <= w or n <= s:
                raise ValueError("Region must have finite bounds with west < east and south < north.")
            if not self.projection.startswith(("X", "x")) and (s < -90 or n > 90 or e-w > 360.001):
                raise ValueError("Geographic bounds require latitudes in [-90, 90] and longitude span <= 360.")
            if self.projection.startswith(("M", "m")) and (s <= -90 or n >= 90):
                raise ValueError("Mercator cannot include a pole. Use a polar or global projection, or narrow the latitude range.")
            if self.projection == "IntMollOcean" and (e-w < 359 or s > -89 or n < 89):
                raise ValueError("Interrupted Mollweide Ocean is a global layout. Choose a regional projection for this region.")
        if not self.projection or any(c.isspace() for c in self.projection):
            raise ValueError("Enter one GMT projection code, without spaces (for example M16c).")
        if self.cpt_range and (not all(math.isfinite(v) for v in self.cpt_range) or self.cpt_range[0] >= self.cpt_range[1]):
            raise ValueError("Color range requires finite minimum < maximum.")
        if not 36 <= self.dpi <= 2400 or not 2 <= self.cpt_levels <= 4096:
            raise ValueError("DPI must be 36–2400; color levels must be 2–4096.")
        if any(not math.isfinite(v) or v <= 0 for v in (self.title_size, self.annotation_size, self.label_size)):
            raise ValueError("Font sizes must be positive finite values.")
        if any(not math.isfinite(v) or v < 0 for v in (self.x_interval, self.y_interval)):
            raise ValueError("Tick intervals must be nonnegative finite values.")
        if self.projection_mode not in ("auto", "manual") or self.mask_mode not in ("none", "land", "ocean"):
            raise ValueError("Invalid projection policy or masking mode.")
        if self.border_mode not in ("none", "cn_l1", "cn_la", "gmt_global", "global_cn_l1", "global_cn_la"):
            raise ValueError("Invalid border mode.")
        if self.interpolation not in ("n", "l", "c", "b") or self.coast_resolution not in ("c", "l", "i", "h", "f", "a"):
            raise ValueError("Invalid interpolation or coastline resolution.")
        if not re.fullmatch(r"[WESNwesnlbrtZz0-9]*", self.frame_sides):
            raise ValueError("Frame sides use GMT letters, for example WSen or WESN.")
        parse_gmt_conf(self.gmt_conf)
        for value in (self.extra_args, self.makecpt_args, self.coast_args, self.colorbar_args):
            shlex.split(value)  # report malformed quotes instead of silently ignoring options
        for token in shlex.split(self.extra_args):
            if token.startswith(("-J", "-R", "-X", "-Y", "-p", "-C")):
                raise ValueError("Set projection, region and palette with their dedicated controls. Origin/perspective overrides cannot be used with map selection.")


def parse_gmt_conf(value: str) -> Dict[str, str]:
    """Split on assignment boundaries, preserving commas in font and pen values."""
    result = {}
    for item in re.split(r"[,;\s]+(?=[A-Za-z][A-Za-z0-9_]*\s*=)", value.strip()):
        if not item:
            continue
        if "=" not in item:
            raise ValueError(f"Invalid GMT setting: {item}. Use KEY=value.")
        key, val = item.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key.strip()) or not val.strip():
            raise ValueError(f"Invalid GMT setting: {item}")
        result[key.strip()] = val.strip()
    return result


class GMTEngine:
    """Interface to the GMT 6 binary."""

    # Scientific and geophysical GMT color palettes
    CPT_OPTIONS = [
        "panoply",    # Classic NASA Panoply rainbow (GMT built-in)
        "turbo",      # Google Turbo smoothed rainbow
        "rainbow",    # Classic GMT rainbow
        "seis",       # Seismic red-white-blue diverging
        "polar",      # Blue-white-red diverging
        "vik",        # Crameri perceptually uniform diverging
        "roma",       # Crameri diverging
        "batlow",     # Crameri modern geoscientific standard
        "viridis",    # Perceptually uniform sequential
        "plasma",     # Warm sequential
        "magma",      # Magma sequential
        "inferno",    # Inferno sequential
        "jet",        # Classic Jet
        "relief",     # Shaded relief topography
        "topo",       # Sandwell/Smith land/sea topography
        "ocean",      # Ocean bathymetry
        "gray",       # Grayscale
        "categorical", # Discrete qualitative palette for flag/class grids
    ]

    CATEGORICAL_RGB = [
        (31, 119, 180),
        (255, 127, 14),
        (44, 160, 44),
        (214, 39, 40),
        (148, 103, 189),
        (140, 86, 75),
        (227, 119, 194),
        (188, 189, 34),
        (23, 190, 207),
        (174, 199, 232),
        (255, 187, 120),
        (152, 223, 138),
        (255, 152, 150),
        (197, 176, 213),
        (196, 156, 148),
        (247, 182, 210),
        (219, 219, 141),
        (158, 218, 229),
        (57, 59, 121),
        (99, 121, 57),
        (140, 109, 49),
        (132, 60, 57),
        (123, 65, 115),
        (82, 84, 163),
    ]

    # Baseline map projections fallback
    PROJECTIONS = [
        ("Interrupted Mollweide Global Oceans [Recommended Ocean Basin]", "IntMollOcean"),
        ("Equidistant Cylindrical (-JQ16c)", "Q16c"),
        ("Robinson Global (-JR16c)", "R16c"),
        ("Mollweide Equal-Area (-JW16c)", "W16c"),
        ("Hammer Equal-Area (-JH16c)", "H16c"),
        ("Mercator (-JM16c)", "M16c"),
        ("North Polar Stereographic (-JS0/90/15c)", "S0/90/15c"),
        ("South Polar Stereographic (-JS0/-90/15c)", "S0/-90/15c"),
        ("Cartesian Linear (-JX16c/8cd)", "X16c/8cd"),
    ]

    @classmethod
    def get_recommended_projections(
        cls,
        region: Optional[Tuple[float, float, float, float]] = None,
        var_name: str = "",
        var_attrs: Optional[Dict[str, Any]] = None
    ) -> List[Tuple[str, str, str]]:
        """
        Dynamically recommends cartographic projections based on:
        1. Variable domain semantics (marine/oceanic/gravity vs terrestrial/atmospheric)
        2. Bounding box coordinates and geographic extent (global vs regional vs polar)
        3. Aspect ratio and elongation (East-West elongated vs North-South elongated)
        4. True data centroid centering (clon, clat) and tailored standard parallels.

        Returns list of tuples: (display_label, projection_code, category_note)
        """
        # Analyze variable domain semantics
        var_name_lower = (var_name or "").lower()
        attr_text = ""
        if var_attrs:
            for k in ("standard_name", "long_name", "units", "comment", "description"):
                if k in var_attrs:
                    attr_text += " " + str(var_attrs[k]).lower()
        full_meta_text = f"{var_name_lower} {attr_text}"

        ocean_keywords = (
            "txx", "tyy", "tzz", "txy", "txz", "tyz", "ssh", "sst", "sla", "adt",
            "bathymetry", "bathy", "ocean", "sea", "salinity", "geoid", "gravity",
            "anom", "dov", "current", "uo", "vo", "wave", "swh", "tide"
        )
        words = set(re.findall(r"[a-z0-9]+", full_meta_text))
        is_ocean = any(k in words for k in ocean_keywords)

        if not region:
            if is_ocean:
                return [
                    ("Interrupted Mollweide Global Oceans [Recommended Ocean Basins]", "IntMollOcean", "Ocean"),
                    ("Mollweide Equal-Area (-JW0/16c) [Recommended Marine Equal-Area]", "W0/16c", "Global"),
                    ("Robinson Global (-JR0/16c) [Recommended Atlas Compromise]", "R0/16c", "Global"),
                    ("Hammer Equal-Area (-JH0/16c) [Global Equal-Area]", "H0/16c", "Global"),
                    ("Equidistant Cylindrical (-JQ16c) [Plate Carree Standard]", "Q16c", "Global"),
                    ("Eckert IV Equal-Area (-JKf0/16c) [Pseudocylindrical]", "Kf0/16c", "Global"),
                    ("Orthographic 3D Globe (-JG0/15/16c) [Globe Perspective]", "G0/15/16c", "Global"),
                    ("Mercator (-JM16c) [Conformal Navigation]", "M16c", "Global"),
                    ("Cartesian Linear (-JX16c/8cd) [Data Space]", "X16c/8cd", "Linear"),
                ]
            else:
                return [
                    ("Robinson Global (-JR0/16c) [Recommended World Atlas]", "R0/16c", "Global"),
                    ("Eckert IV Equal-Area (-JKf0/16c) [Recommended Thematic Equal-Area]", "Kf0/16c", "Global"),
                    ("Equidistant Cylindrical (-JQ16c) [Standard Plate Carree]", "Q16c", "Global"),
                    ("Mollweide Equal-Area (-JW0/16c) [Thematic Equal-Area]", "W0/16c", "Global"),
                    ("Hammer Equal-Area (-JH0/16c) [Global Equal-Area]", "H0/16c", "Global"),
                    ("Orthographic 3D Globe (-JG0/20/16c) [Globe Perspective]", "G0/20/16c", "Global"),
                    ("Interrupted Mollweide Global Oceans [Ocean Basins]", "IntMollOcean", "Ocean"),
                    ("Mercator (-JM16c) [Conformal Navigation]", "M16c", "Global"),
                    ("Cartesian Linear (-JX16c/8cd) [Data Space]", "X16c/8cd", "Linear"),
                ]

        w, e, s, n = region
        dlon = abs(e - w)
        s_deg = min(s, n)
        n_deg = max(s, n)
        dlat = max(0.001, n_deg - s_deg)
        clon = (w + e) / 2.0
        clat = (s_deg + n_deg) / 2.0

        # Standard parallels for conic projections
        p1 = max(-80.0, min(80.0, clat - dlat * 0.25))
        p2 = max(-80.0, min(80.0, clat + dlat * 0.25))
        if abs(p1 - p2) < 0.5:
            p1 = max(-80.0, clat - 1.0)
            p2 = min(80.0, clat + 1.0)

        # Aspect ratio taking latitude convergence into account
        clat_rad = math.radians(min(89.0, max(-89.0, clat)))
        effective_dlon = dlon * math.cos(clat_rad)
        aspect_ratio = effective_dlon / dlat if dlat > 0 else 1.0

        # 1. North Polar
        if s_deg >= 50.0 or (n_deg >= 70.0 and clat >= 60.0):
            return [
                ("North Polar Stereographic (-JS0/90/15c) [Recommended Arctic Conformal]", "S0/90/15c", "Polar"),
                ("Lambert Azimuthal Polar (-JA0/90/15c) [Recommended Arctic Equal-Area]", "A0/90/15c", "Polar"),
                ("Orthographic Arctic Globe (-JG0/90/15c) [Arctic 3D Perspective]", "G0/90/15c", "Polar"),
                (f"Lambert Conformal Conic (-JL{clon:.1f}/75/{p1:.1f}/{p2:.1f}/15c) [High-Lat Conic]", f"L{clon:.1f}/75/{p1:.1f}/{p2:.1f}/15c", "Conic"),
                ("Gnomonic Polar (-JF0/90/15c) [Great Circle Navigation]", "F0/90/15c", "Polar"),
                ("Equidistant Cylindrical (-JQ16c) [Plate Carree]", "Q16c", "Cylindrical"),
                ("Cartesian Linear (-JX16c/10c) [Data Space]", "X16c/10c", "Linear"),
            ]

        # 2. South Polar
        if n_deg <= -50.0 or (s_deg <= -70.0 and clat <= -60.0):
            return [
                ("South Polar Stereographic (-JS0/-90/15c) [Recommended Antarctic Conformal]", "S0/-90/15c", "Polar"),
                ("Lambert Azimuthal Polar (-JA0/-90/15c) [Recommended Antarctic Equal-Area]", "A0/-90/15c", "Polar"),
                ("Orthographic Antarctic Globe (-JG0/-90/15c) [Antarctic 3D Perspective]", "G0/-90/15c", "Polar"),
                (f"Lambert Conformal Conic (-JL{clon:.1f}/-75/{p1:.1f}/{p2:.1f}/15c) [High-Lat Conic]", f"L{clon:.1f}/-75/{p1:.1f}/{p2:.1f}/15c", "Conic"),
                ("Equidistant Cylindrical (-JQ16c) [Plate Carree]", "Q16c", "Cylindrical"),
                ("Cartesian Linear (-JX16c/10c) [Data Space]", "X16c/10c", "Linear"),
            ]

        # 3. Near Global (Global span)
        if dlon >= 260.0 and dlat >= 100.0:
            if is_ocean:
                return [
                    *([("Interrupted Mollweide Global Oceans [Recommended Ocean Basins]", "IntMollOcean", "Ocean")] if dlon >= 359 and s <= -89 and n >= 89 else []),
                    (f"Mollweide Equal-Area (-JW{clon:.0f}/16c) [Recommended Marine Equal-Area]", f"W{clon:.0f}/16c", "Global"),
                    (f"Robinson Global (-JR{clon:.0f}/16c) [Recommended Atlas Compromise]", f"R{clon:.0f}/16c", "Global"),
                    (f"Hammer Equal-Area (-JH{clon:.0f}/16c) [Global Equal-Area]", f"H{clon:.0f}/16c", "Global"),
                    ("Equidistant Cylindrical (-JQ16c) [Plate Carree Standard]", "Q16c", "Global"),
                    (f"Eckert IV Equal-Area (-JKf{clon:.0f}/16c) [Pseudocylindrical]", f"Kf{clon:.0f}/16c", "Global"),
                    (f"Orthographic 3D Globe (-JG{clon:.0f}/15/16c) [Globe Perspective]", f"G{clon:.0f}/15/16c", "Global"),
                    ("Mercator (-JM16c) [Conformal Navigation]", "M16c", "Global"),
                    ("Cartesian Linear (-JX16c/8cd) [Data Space]", "X16c/8cd", "Linear"),
                ]
            else:
                return [
                    (f"Robinson Global (-JR{clon:.0f}/16c) [Recommended World Atlas]", f"R{clon:.0f}/16c", "Global"),
                    (f"Eckert IV Equal-Area (-JKf{clon:.0f}/16c) [Recommended Equal-Area]", f"Kf{clon:.0f}/16c", "Global"),
                    ("Equidistant Cylindrical (-JQ16c) [Plate Carree Standard]", "Q16c", "Global"),
                    (f"Mollweide Equal-Area (-JW{clon:.0f}/16c) [Equal-Area Elliptic]", f"W{clon:.0f}/16c", "Global"),
                    (f"Hammer Equal-Area (-JH{clon:.0f}/16c) [Global Equal-Area]", f"H{clon:.0f}/16c", "Global"),
                    (f"Orthographic 3D Globe (-JG{clon:.0f}/20/16c) [Globe Perspective]", f"G{clon:.0f}/20/16c", "Global"),
                    ("Interrupted Mollweide Global Oceans [Ocean Basins]", "IntMollOcean", "Ocean"),
                    ("Mercator (-JM16c) [Conformal Navigation]", "M16c", "Global"),
                    ("Cartesian Linear (-JX16c/8cd) [Data Space]", "X16c/8cd", "Linear"),
                ]

        # Conic projections are singular when their standard parallels are symmetric
        # around the equator. Use a cylindrical map for equatorial regions.
        if abs(p1 + p2) < 0.5:
            return [("Equidistant Cylindrical [Equatorial]", f"Q{clon:.2f}/16c", "Cylindrical"),
                    ("Mercator [Conformal]", "M16c", "Cylindrical"),
                    ("Cartesian Linear", "X16c/10c", "Linear")]

        # 4. High-Latitude Regional (42N-70N or 42S-70S)
        if abs(clat) >= 42.0:
            pole_str = "90" if clat > 0 else "-90"
            return [
                (f"Lambert Conformal Conic (-JL{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c) [Recommended High-Lat Conformal]", f"L{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c", "Conic"),
                (f"Albers Equal-Area Conic (-JB{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c) [High-Lat Equal-Area]", f"B{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c", "Conic"),
                (f"Lambert Azimuthal Equal-Area (-JA{clon:.2f}/{clat:.2f}/16c) [Regional Azimuthal]", f"A{clon:.2f}/{clat:.2f}/16c", "Azimuthal"),
                (f"Polar Stereographic (-JS{clon:.2f}/{pole_str}/16c)", f"S{clon:.2f}/{pole_str}/16c", "Polar"),
                ("Mercator (-JM16c) [Regional Conformal]", "M16c", "Cylindrical"),
                ("Equidistant Cylindrical (-JQ16c) [Plate Carree]", "Q16c", "Cylindrical"),
                ("Cartesian Linear (-JX16c/10c) [Data Space]", "X16c/10c", "Linear"),
            ]

        # 5. Mid / Low-Latitude Regional (within 42S - 42N)
        # Subcase 5A: East-West Elongated
        if aspect_ratio >= 1.4:
            return [
                (f"Lambert Conformal Conic (-JL{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c) [Recommended E-W Conformal]", f"L{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c", "Conic"),
                (f"Albers Equal-Area Conic (-JB{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c) [Recommended E-W Equal-Area]", f"B{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c", "Conic"),
                ("Mercator (-JM16c) [Regional Conformal]", "M16c", "Cylindrical"),
                ("Equidistant Cylindrical (-JQ16c) [Plate Carree]", "Q16c", "Cylindrical"),
                ("Cartesian Linear (-JX16c/10c) [Data Space]", "X16c/10c", "Linear"),
            ]

        # Subcase 5B: North-South Elongated
        if aspect_ratio <= 0.75:
            return [
                (f"Transverse Mercator (-JT{clon:.2f}/16c) [Recommended N-S Conformal]", f"T{clon:.2f}/16c", "Cylindrical"),
                (f"Cassini Cylindrical (-JC{clon:.2f}/{clat:.2f}/16c) [N-S Transverse Cylindrical]", f"C{clon:.2f}/{clat:.2f}/16c", "Cylindrical"),
                ("Mercator (-JM16c) [Regional Conformal]", "M16c", "Cylindrical"),
                ("Equidistant Cylindrical (-JQ16c) [Plate Carree]", "Q16c", "Cylindrical"),
                ("Cartesian Linear (-JX16c/12c) [Data Space]", "X16c/12c", "Linear"),
            ]

        # Subcase 5C: Compact / Balanced Regional
        return [
            ("Mercator (-JM16c) [Recommended Regional Conformal]", "M16c", "Cylindrical"),
            (f"Lambert Azimuthal Equal-Area (-JA{clon:.2f}/{clat:.2f}/16c) [Recommended Regional Equal-Area]", f"A{clon:.2f}/{clat:.2f}/16c", "Azimuthal"),
            (f"Orthographic Perspective (-JG{clon:.2f}/{clat:.2f}/16c) [Centered Perspective]", f"G{clon:.2f}/{clat:.2f}/16c", "Azimuthal"),
            (f"Lambert Conformal Conic (-JL{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c) [Conic Conformal]", f"L{clon:.2f}/{clat:.2f}/{p1:.2f}/{p2:.2f}/16c", "Conic"),
            ("Equidistant Cylindrical (-JQ16c) [Plate Carree]", "Q16c", "Cylindrical"),
            ("Cartesian Linear (-JX16c/10c) [Data Space]", "X16c/10c", "Linear"),
        ]

    # (central meridian, width, region, x origin, y origin), in cm.
    SECTORS = [
        (60, 9, (20, 110, 0, 90), 0, 9),
        (190, 15, (110, 260, 0, 90), 9, 9),
        (-30, 12, (-100, 20, 0, 90), 24, 9),
        (90, 12, (20, 140, -90, 0), 0, 0),
        (220, 15, (140, 290, -90, 0), 12, 0),
        (-20, 9, (-70, 20, -90, 0), 27, 0),
    ]

    def __init__(self, gmt_bin: Optional[str] = None):
        self.gmt_bin = self._find_gmt(gmt_bin)
        if not self.gmt_bin:
            raise RuntimeError("GMT 6 was not found. Install GMT and Ghostscript in the Python environment, add GMT to PATH, or set GMT_BIN.")
        self._cache_owner = tempfile.TemporaryDirectory(prefix="graticule_cache_")
        self._temp_cache_dir = self._cache_owner.name
        self._grid_info_cache = OrderedDict()
        self._preview_cache = OrderedDict()
        self._dims_cache = OrderedDict()
        self._lock = threading.RLock()

    @classmethod
    def _find_gmt(cls, explicit_path=None):
        candidates = [explicit_path, os.environ.get("GMT_BIN"),
                      str(Path(sys.executable).parent / "gmt"), shutil.which("gmt"),
                      "/opt/local/lib/gmt6/bin/gmt", "/opt/local/bin/gmt6", "/opt/local/bin/gmt",
                      "/opt/homebrew/bin/gmt", "/usr/local/bin/gmt", "/usr/bin/gmt"]
        return next((os.path.abspath(p) for p in candidates if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)

    def close(self):
        self._cache_owner.cleanup()

    def child_path(self, base_path: Optional[str] = None) -> str:
        """Build a child PATH containing GMT, MacPorts/Homebrew bins (for gs), and Python."""
        raw_path = os.environ.get("PATH", "") if base_path is None else base_path
        gmt_dir = os.path.dirname(self.gmt_bin)
        candidates: List[str] = [gmt_dir]

        # Handle MacPorts layout such as /opt/local/lib/gmt6/bin/gmt -> /opt/local/bin
        gmt_path = Path(self.gmt_bin)
        for parent in gmt_path.parents:
            if parent.name.startswith("gmt") and parent.parent.name == "lib":
                prefix_bin = str(parent.parent.parent / "bin")
                candidates.append(prefix_bin)
                break

        candidates.extend([
            str(Path(sys.executable).parent),
            "/opt/local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])
        candidates.extend(raw_path.split(os.pathsep) if raw_path else [])
        candidates.extend(["/usr/bin", "/bin"])

        seen = set()
        ordered: List[str] = []
        for entry in candidates:
            if entry and entry not in seen:
                seen.add(entry)
                ordered.append(entry)
        return os.pathsep.join(ordered)

    def _env(self, directory):
        env = os.environ.copy()
        env.update(GMT_USERDIR=directory, GMT_TMPDIR=directory,
                   GMT_SESSION_NAME=uuid.uuid4().hex, GMT_HISTORY="false")
        env["PATH"] = self.child_path(env.get("PATH", ""))
        return env

    def _run(self, args, input=None):
        """Classic operations have isolated histories and never modify the user's cwd."""
        with tempfile.TemporaryDirectory() as td:
            res = subprocess.run([self.gmt_bin, *args, "--GMT_HISTORY=false"], input=input,
                                 cwd=td, env=self._env(td), capture_output=True, text=True, timeout=180)
        if res.returncode:
            raise RuntimeError(f"GMT {args[0]} failed:\n{res.stderr.strip()}")
        return res

    @staticmethod
    def _remember(cache, key, value, limit=64):
        cache[key] = value
        cache.move_to_end(key)
        while len(cache) > limit:
            _, old = cache.popitem(last=False)
            if isinstance(old, str) and os.path.isfile(old):
                os.unlink(old)
        return value

    @staticmethod
    def _resolve_grid_spec(grid_spec: str) -> str:
        file_path, var_name, slice_tuple = GMTEngine._parse_grid_spec(grid_spec)
        if not file_path or not file_path.lower().endswith(".npz"):
            return grid_spec
        resolved = resolve_nc_path(file_path)
        if var_name is None:
            return resolved
        suffix = "[" + ",".join(str(i) for i in slice_tuple) + "]" if slice_tuple else ""
        return f"{resolved}?{var_name}{suffix}"

    @staticmethod
    def _source_key(grid_spec):
        resolved_spec = GMTEngine._resolve_grid_spec(grid_spec)
        path = resolved_spec.split("?", 1)[0]
        stat = os.stat(path)
        return resolved_spec, stat.st_mtime_ns, stat.st_size

    def get_version(self):
        return subprocess.run([self.gmt_bin, "--version"], capture_output=True, text=True, check=True).stdout.strip()

    def get_grid_info(self, grid_spec, force_refresh=False, scan=True):
        grid_spec = self._resolve_grid_spec(grid_spec)
        key = self._source_key(grid_spec) + (scan,)
        with self._lock:
            if not force_refresh and key in self._grid_info_cache:
                return self._grid_info_cache[key].copy()
        args = ["grdinfo", grid_spec, "-Cn"]
        if scan:
            args.append("-M")
        # -Cn omits the filename so paths containing spaces are unambiguous.
        tokens = self._run(args).stdout.split()
        if len(tokens) < 10:
            raise ValueError("GMT returned incomplete grid metadata.")
        names = ("x_min", "x_max", "y_min", "y_max", "z_min", "z_max", "dx", "dy", "nx", "ny")
        info = {name: (int(float(val)) if name in ("nx", "ny") else float(val)) for name, val in zip(names, tokens)}
        info["file"] = grid_spec
        with self._lock:
            self._remember(self._grid_info_cache, key, info)
        return info.copy()

    @staticmethod
    def _parse_grid_spec(grid_spec: str) -> Tuple[str, Optional[str], Tuple[int, ...]]:
        if "?" not in grid_spec:
            return grid_spec, None, ()
        file_path, rest = grid_spec.split("?", 1)
        if "[" in rest and rest.endswith("]"):
            var_part, idx_part = rest[:-1].split("[", 1)
            indices = tuple(int(x.strip()) for x in idx_part.split(",") if x.strip())
            return file_path, (var_part or None), indices
        return file_path, (rest or None), ()

    @staticmethod
    def _region_covers_grid(region: Optional[Tuple[float, float, float, float]], info: Dict[str, Any]) -> bool:
        if region is None:
            return True
        w, e, s, n = region
        dx = max(0.0, float(info.get("dx", 0.0)))
        dy = max(0.0, float(info.get("dy", 0.0)))
        covers_x = (w <= info["x_min"] + dx and e >= info["x_max"] - dx) or (
            (info["x_max"] - info["x_min"]) >= 359.5 and (e - w) >= 359.5
        )
        covers_y = s <= info["y_min"] + dy and n >= info["y_max"] - dy
        return covers_x and covers_y

    @staticmethod
    def _estimated_cells(info: Dict[str, Any], region: Optional[Tuple[float, float, float, float]]) -> float:
        nx = max(1, int(info["nx"]))
        ny = max(1, int(info["ny"]))
        if region is None:
            return float(nx * ny)
        w, e, s, n = region
        dx = max(1e-12, float(info["dx"]))
        dy = max(1e-12, float(info["dy"]))
        span_x = max(0.0, min(e, info["x_max"]) - max(w, info["x_min"]))
        span_y = max(0.0, min(n, info["y_max"]) - max(s, info["y_min"]))
        if span_x <= 0.0 or span_y <= 0.0:
            # Periodic longitude wrap can lie outside [x_min, x_max] while still valid.
            span_x = min(e - w, info["x_max"] - info["x_min"])
            span_y = min(n - s, info["y_max"] - info["y_min"])
        est_nx = min(nx, max(1.0, span_x / dx + 1.0))
        est_ny = min(ny, max(1.0, span_y / dy + 1.0))
        return est_nx * est_ny

    def _fast_netcdf_subgrid(
        self,
        grid_spec: str,
        region: Optional[Tuple[float, float, float, float]],
        target_path: str,
        max_nx: int = 2000,
        max_ny: int = 1000,
    ) -> bool:
        """Row-wise contiguous NetCDF decimation for massive grids without loading full arrays into RAM."""
        file_path, var_name, slice_tuple = self._parse_grid_spec(grid_spec)
        if not os.path.isfile(file_path):
            return False
        try:
            import netCDF4
        except ImportError:
            return False

        out = None
        try:
            with netCDF4.Dataset(file_path, "r") as ds:
                if var_name is None:
                    var_name = next(
                        (
                            k for k, v in ds.variables.items()
                            if k not in ds.dimensions and v.ndim >= 2 and np.issubdtype(v.dtype, np.number)
                        ),
                        None,
                    )
                if not var_name or var_name not in ds.variables:
                    return False
                var = ds.variables[var_name]
                if var.ndim < 2 or len(slice_tuple) + 2 != var.ndim:
                    return False
                y_dim, x_dim = var.dimensions[-2], var.dimensions[-1]
                if y_dim not in ds.variables or x_dim not in ds.variables:
                    return False

                x_var = ds.variables[x_dim]
                y_var = ds.variables[y_dim]
                x_vals = np.asarray(x_var[:], dtype=np.float64)
                y_vals = np.asarray(y_var[:], dtype=np.float64)
                if x_vals.ndim != 1 or y_vals.ndim != 1 or x_vals.size < 2 or y_vals.size < 2:
                    return False
                if not (np.isfinite(x_vals).all() and np.isfinite(y_vals).all()):
                    return False

                dx_diffs = np.diff(x_vals)
                dy_diffs = np.diff(y_vals)
                if abs(dx_diffs[0]) <= 0 or abs(dy_diffs[0]) <= 0:
                    return False
                if not (
                    np.allclose(dx_diffs, dx_diffs[0], rtol=1e-4, atol=1e-8)
                    and np.allclose(dy_diffs, dy_diffs[0], rtol=1e-4, atol=1e-8)
                ):
                    return False

                nx_src = int(x_vals.size)
                ny_src = int(y_vals.size)
                x_min = float(min(x_vals[0], x_vals[-1]))
                x_max = float(max(x_vals[0], x_vals[-1]))
                y_min = float(min(y_vals[0], y_vals[-1]))
                y_max = float(max(y_vals[0], y_vals[-1]))
                dx_signed = float(x_vals[-1] - x_vals[0]) / float(nx_src - 1)
                dy_signed = float(y_vals[-1] - y_vals[0]) / float(ny_src - 1)
                dx_src = abs(dx_signed)
                dy_src = abs(dy_signed)

                x_units = str(getattr(x_var, "units", "")).lower()
                y_units = str(getattr(y_var, "units", "")).lower()
                x_std = str(getattr(x_var, "standard_name", "")).lower()
                y_std = str(getattr(y_var, "standard_name", "")).lower()
                is_geo = (
                    (x_dim.lower() in ("lon", "longitude", "glon") or "degree" in x_units or x_std == "longitude")
                    and (y_dim.lower() in ("lat", "latitude", "glat") or "degree" in y_units or y_std == "latitude")
                )
                is_global_x = is_geo and ((x_max - x_min + dx_src) >= 359.9)
                is_global_y = is_geo and ((y_max - y_min + dy_src) >= 179.9)

                if region is None:
                    out_w, out_e = ((-180.0, 180.0) if x_min < -1.0 else (0.0, 360.0)) if is_global_x else (x_min, x_max)
                    out_s, out_n = (-90.0, 90.0) if is_global_y else (y_min, y_max)
                else:
                    rw, re_, rs, rn = region
                    if is_global_x and (re_ - rw) >= 359.0:
                        out_w, out_e = (-180.0, 180.0) if rw < -1.0 else (0.0, 360.0)
                    elif is_global_x:
                        out_w, out_e = rw - dx_src, re_ + dx_src
                    else:
                        out_w = max(x_min, rw - dx_src)
                        out_e = min(x_max, re_ + dx_src)

                    if is_global_y and (rn - rs) >= 179.0:
                        out_s, out_n = -90.0, 90.0
                    else:
                        out_s = -90.0 if (is_global_y and rs <= -89.9) else max(y_min, rs - dy_src)
                        out_n = 90.0 if (is_global_y and rn >= 89.9) else min(y_max, rn + dy_src)

                if out_e <= out_w or out_n <= out_s:
                    return False

                sub_nx = max(2, int(round((out_e - out_w) / dx_src)) + 1)
                sub_ny = max(2, int(round((out_n - out_s) / dy_src)) + 1)
                target_nx = min(sub_nx, max_nx)
                target_ny = min(sub_ny, max_ny)

                out_x = np.linspace(out_w, out_e, target_nx, dtype=np.float64)
                out_y = np.linspace(out_s, out_n, target_ny, dtype=np.float64)

                src_y_idx = np.clip(np.rint((out_y - float(y_vals[0])) / dy_signed).astype(np.int64), 0, ny_src - 1)
                if is_global_x:
                    if dx_signed > 0:
                        src_x_idx = np.rint(((out_x - float(x_vals[0])) % 360.0) / dx_src).astype(np.int64) % nx_src
                    else:
                        src_x_idx = np.rint(((float(x_vals[0]) - out_x) % 360.0) / dx_src).astype(np.int64) % nx_src
                else:
                    src_x_idx = np.clip(np.rint((out_x - float(x_vals[0])) / dx_signed).astype(np.int64), 0, nx_src - 1)

                x_lo = int(src_x_idx.min())
                x_hi = int(src_x_idx.max())
                use_slice_x = (x_hi - x_lo + 1) <= max(2, nx_src // 2)
                local_x_idx = (src_x_idx - x_lo) if use_slice_x else src_x_idx

                var.set_auto_maskandscale(True)
                out = np.empty((target_ny, target_nx), dtype=np.float32)
                last_sy = None
                last_row = None

                for row_out_idx, sy in enumerate(src_y_idx):
                    sy_int = int(sy)
                    if sy_int != last_sy:
                        if use_slice_x:
                            raw_row = var[slice_tuple + (sy_int, slice(x_lo, x_hi + 1))]
                        else:
                            raw_row = var[slice_tuple + (sy_int, slice(None))]
                        if np.ma.isMaskedArray(raw_row):
                            last_row = np.asarray(raw_row.filled(np.nan), dtype=np.float32)
                        else:
                            last_row = np.asarray(raw_row, dtype=np.float32)
                        last_sy = sy_int
                    out[row_out_idx] = last_row[local_x_idx]

                with netCDF4.Dataset(target_path, "w", format="NETCDF4_CLASSIC") as dst:
                    dst.Conventions = "CF-1.7"
                    y_out_name = "lat" if is_geo else "y"
                    x_out_name = "lon" if is_geo else "x"
                    dst.createDimension(y_out_name, target_ny)
                    dst.createDimension(x_out_name, target_nx)

                    vy = dst.createVariable(y_out_name, "f8", (y_out_name,))
                    vx = dst.createVariable(x_out_name, "f8", (x_out_name,))
                    vy[:] = out_y
                    vx[:] = out_x
                    vx.actual_range = [float(out_w), float(out_e)]
                    vy.actual_range = [float(out_s), float(out_n)]
                    if is_geo:
                        vx.long_name = "longitude"
                        vx.units = "degrees_east"
                        vx.standard_name = "longitude"
                        vx.axis = "X"
                        vy.long_name = "latitude"
                        vy.units = "degrees_north"
                        vy.standard_name = "latitude"
                        vy.axis = "Y"

                    vz = dst.createVariable("z", "f4", (y_out_name, x_out_name), fill_value=np.float32(np.nan))
                    vz.node_offset = 0
                    vz[:] = out
                    finite_mask = np.isfinite(out)
                    if finite_mask.any():
                        vz.actual_range = [float(out[finite_mask].min()), float(out[finite_mask].max())]
                    for attr_name in ("long_name", "standard_name", "units"):
                        if hasattr(var, attr_name):
                            setattr(vz, attr_name, getattr(var, attr_name))
            return True
        except (OSError, RuntimeError, ValueError):
            if os.path.exists(target_path):
                try:
                    os.unlink(target_path)
                except OSError:
                    pass
            return False
        finally:
            if out is not None:
                del out
                gc.collect()

    def get_masked_grid_info(self, grid_spec, region, mask_mode):
        key = self._source_key(grid_spec) + (tuple(region) if region else None, mask_mode)
        with self._lock:
            if key in self._grid_info_cache:
                return self._grid_info_cache[key].copy()

        base_info = self.get_grid_info(grid_spec, scan=False)
        scan_source = grid_spec
        if self._estimated_cells(base_info, region) > 16_000_000:
            scan_source = self._get_or_create_preview_grid(
                grid_spec,
                region,
                max_nx=4000,
                max_ny=2000,
                cell_threshold=16_000_000,
            )
            base_info = self.get_grid_info(scan_source, scan=False)

        with tempfile.TemporaryDirectory(dir=self._temp_cache_dir) as td:
            grid = scan_source
            if region and not self._region_covers_grid(region, base_info):
                cut_region = tuple(region)
                if (base_info["x_max"] - base_info["x_min"]) >= 359.5 and (cut_region[1] - cut_region[0]) >= 359.5:
                    cut_region = (base_info["x_min"], base_info["x_max"], cut_region[2], cut_region[3])
                grid = os.path.join(td, "cut.nc")
                self._run(["grdcut", scan_source, self._region_flag(cut_region), f"-G{grid}"])
            if mask_mode != "none":
                mask = os.path.join(td, "mask.nc")
                masked = os.path.join(td, "masked.nc")
                self._run(["grdlandmask", f"-R{grid}", f"-G{mask}", "-N1/NaN" if mask_mode == "land" else "-NNaN/1", "-Dl"])
                self._run(["grdmath", grid, mask, "MUL", "=", masked])
                grid = masked
            info = self.get_grid_info(grid)
        if not all(math.isfinite(info[k]) for k in ("z_min", "z_max")):
            raise ValueError("The selected region/slice contains no finite, unmasked data.")
        info["file"] = grid_spec
        with self._lock:
            self._remember(self._grid_info_cache, key, info)
        return info

    @staticmethod
    def _region_flag(region):
        return "-R" + "/".join(f"{v:.15g}" for v in region)

    @staticmethod
    def _projection_settings(gmt_conf):
        return tuple((k, v) for k, v in parse_gmt_conf(gmt_conf).items() if k.startswith("PROJ_") and k != "PROJ_LENGTH_UNIT")

    def get_map_dimensions_cm(self, region, projection, gmt_conf=""):
        if projection == "IntMollOcean":
            return 36.0, 18.0
        key = (tuple(region) if region else (0, 360, -90, 90), projection, self._projection_settings(gmt_conf))
        with self._lock:
            if key in self._dims_cache:
                return self._dims_cache[key]
        values = self._run(["mapproject", self._region_flag(key[0]), f"-J{projection}", "-W", "-Dc", *[f"--{k}={v}" for k, v in key[2]]]).stdout.split()
        dims = tuple(map(float, values[:2]))
        if len(dims) != 2 or not all(math.isfinite(x) and 0 < x < 500 for x in dims):
            raise ValueError("Projection has invalid or excessive map dimensions. Check its parameters and region.")
        with self._lock:
            self._remember(self._dims_cache, key, dims)
        return dims

    def inverse_project_points(self, points, region, projection, dims_cm, gmt_conf=""):
        """Exact GMT inverse, in a single batch; blank map corners remain NaN."""
        points = np.asarray(points, dtype=float).reshape(-1, 2)
        result = np.full_like(points, np.nan)
        if projection == "IntMollOcean":
            xy = points * np.asarray(dims_cm)
            for clon, width, sector, ox, oy in self.SECTORS:
                dims = self.get_map_dimensions_cm(sector, f"W{clon}/{width}c", gmt_conf)
                inside = ((xy[:, 0] >= ox) & (xy[:, 0] <= ox+dims[0]) &
                          (xy[:, 1] >= oy) & (xy[:, 1] <= oy+dims[1]))
                if inside.any():
                    local = (xy[inside] - [ox, oy]) / dims
                    vals = self.inverse_project_points(local, sector, f"W{clon}/{width}c", dims, gmt_conf)
                    ids = np.flatnonzero(inside)
                    good = np.isfinite(vals).all(axis=1)
                    result[ids[good]] = vals[good]
            return result
        text = "\n".join(f"{u*dims_cm[0]:.15g}\t{v*dims_cm[1]:.15g}" for u, v in points)
        res = self._run(["mapproject", self._region_flag(region), f"-J{projection}", "-I", "-Dc", "--FORMAT_FLOAT_OUT=%.15g", *[f"--{k}={v}" for k, v in self._projection_settings(gmt_conf)]], input=text)
        rows = res.stdout.splitlines()
        if len(rows) != len(points):
            return result
        for i, row in enumerate(rows):
            try:
                result[i] = list(map(float, row.split()[:2]))
            except ValueError:
                continue
        if not projection.startswith(("X", "x")):
            w, e, s, n = region
            # Choose the longitude branch matching the plotted region.
            result[:, 0] += 360*np.round(((w+e)/2-result[:, 0])/360)
            eps = 1e-6
            good = ((result[:, 0] >= w-eps) & (result[:, 0] <= e+eps) &
                    (result[:, 1] >= s-eps) & (result[:, 1] <= n+eps))
            result[~good] = np.nan
        result[~np.isfinite(result).all(axis=1)] = np.nan
        return result

    def inverse_project_point(self, u, v, region, projection, dims_cm, gmt_conf=""):
        return tuple(self.inverse_project_points([(u, v)], region, projection, dims_cm, gmt_conf)[0])

    @staticmethod
    def default_style_for_variable(var_name: str) -> Tuple[str, bool]:
        """Return default (cpt, symmetric) heuristic for a variable name."""
        name = (var_name or "").lower()
        symmetric = any(k in name for k in ("txx", "tyy", "tzz", "txy", "txz", "tyz", "anom", "dov"))
        if symmetric:
            return "polar", True
        if any(k in name for k in ("elev", "dem", "topo", "altitude")):
            return "relief", False
        if any(k in name for k in ("bathymetry", "bathy", "depth")):
            return "ocean", False
        return "turbo", False

    def compute_selection_region(
        self,
        u0: float,
        v0: float,
        u1: float,
        v1: float,
        region: Tuple[float, float, float, float],
        projection: str,
        dims_cm: Tuple[float, float],
        gmt_conf: str = "",
    ) -> Optional[Tuple[float, float, float, float]]:
        """Sample the selected normalized area, including interior, so curved edges and poles count."""
        if not region or u1 <= u0 or v1 <= v0:
            return None
        u, v = np.meshgrid(np.linspace(u0, u1, 33), np.linspace(v0, v1, 33))
        points = np.column_stack((u.ravel(), v.ravel()))
        if u0 <= 0.5 <= u1 and v0 <= 0.5 <= v1:
            points = np.vstack((points, [0.5, 0.5]))
        coords = self.inverse_project_points(points, region, projection, dims_cm, gmt_conf)
        coords = coords[np.isfinite(coords).all(axis=1)]
        if len(coords) < 2:
            return None
        lo, hi = coords.min(axis=0), coords.max(axis=0)
        w, e, s, n = region
        if not projection.startswith(("X", "x")):
            if hi[1] > 89.999 or lo[1] < -89.999:
                lo[0], hi[0] = w, e
            elif hi[0] - lo[0] > 180:
                # Smallest circular longitude interval preserves dateline crossings.
                values = np.sort(coords[:, 0] % 360)
                gaps = np.diff(np.r_[values, values[0] + 360])
                gap = int(np.argmax(gaps))
                if gaps[gap] > 180:
                    lo[0] = values[(gap + 1) % len(values)]
                    hi[0] = values[gap]
                    if hi[0] < lo[0]:
                        hi[0] += 360
                    shift = 360 * round(((w + e) / 2 - (lo[0] + hi[0]) / 2) / 360)
                    lo[0] += shift
                    hi[0] += shift
        if hi[0] - lo[0] < 1e-8 or hi[1] - lo[1] < 1e-8:
            return None
        return float(lo[0]), float(hi[0]), float(lo[1]), float(hi[1])

    def _get_or_create_preview_grid(
        self,
        grid_spec,
        region,
        max_nx: int = 2000,
        max_ny: int = 1000,
        cell_threshold: int = 3_000_000,
    ):
        info = self.get_grid_info(grid_spec, scan=False)
        r = tuple(region) if region else tuple(info[k] for k in ("x_min", "x_max", "y_min", "y_max"))
        cells = self._estimated_cells(info, r)
        if cells <= cell_threshold:
            return grid_spec
        key = self._source_key(grid_spec) + (r, max_nx, max_ny)
        # Serialize construction so simultaneous requests cannot read half-written grids.
        with self._lock:
            if key in self._preview_cache and os.path.isfile(self._preview_cache[key]):
                self._preview_cache.move_to_end(key)
                return self._preview_cache[key]
            target = os.path.join(self._temp_cache_dir, uuid.uuid4().hex + ".nc")
            if not self._fast_netcdf_subgrid(grid_spec, region, target, max_nx=max_nx, max_ny=max_ny):
                if cells > 50_000_000:
                    raise RuntimeError(
                        "Grid exceeds 50M cells and is not a standard NetCDF regular grid; "
                        "crop the region or pre-resample before plotting."
                    )
                self._run(["grdsample", grid_spec, self._region_flag(r), f"-I{max_nx}+n/{max_ny}+n", f"-G{target}", "-nl+c"])
            return self._remember(self._preview_cache, key, target, 8)

    def resolve_config(self, config):
        config = replace(config, grid_spec=self._resolve_grid_spec(config.grid_spec), slice_indices=dict(config.slice_indices))
        if config.region is None:
            info = self.get_grid_info(config.grid_spec, scan=False)
            config.region = tuple(info[k] for k in ("x_min", "x_max", "y_min", "y_max"))
        if config.projection_mode == "auto":
            config.projection = self.get_recommended_projections(config.region, config.variable_name, {"description": config.variable_description})[0][1] if config.is_geographic else "X16c/10c"
        if os.path.isfile(config.cpt): config.cpt = os.path.abspath(config.cpt)
        config.validate()
        if config.cpt_categorical:
            if config.cpt_range is None:
                if config.flag_values:
                    lo, hi = float(min(config.flag_values)), float(max(config.flag_values))
                    config.cpt_range = (lo, hi) if lo < hi else (lo - 1.0, hi + 1.0)
                else:
                    config.cpt_range = (0.0, 1.0)
            return config
        if config.cpt_range is None:
            scan_grid = self._get_or_create_preview_grid(config.grid_spec, config.region) if config.preview else config.grid_spec
            info = self.get_masked_grid_info(scan_grid, config.region, config.mask_mode)
            lo, hi = info["z_min"], info["z_max"]
            if config.symmetric_cpt:
                hi = max(abs(lo), abs(hi)); lo = -hi
            config.cpt_range = (lo, hi) if lo < hi else (lo-1, hi+1)
        return config

    def _frame_args(self, config, title=True):
        args = []
        if config.show_frame:
            for axis, interval in (("x", config.x_interval), ("y", config.y_interval)):
                stride = f"{interval:.12g}" if interval else ""
                args.append(f"-B{axis}a{stride}f" + (f"g{stride}" if config.show_grid else ""))
            args.append(f"-B{config.frame_sides}" + (f"+t{self._label(config.title)}" if title and config.title else ""))
        return args

    @staticmethod
    def _ps_escape(text):
        # GMT uses ISOLatin1+ encoding by default; convert common UTF-8 symbols to octal escapes.
        return (
            str(text)
            .replace("\n", " ")
            .replace("\u00b0", "\\260")
            .replace("\u00b1", "\\261")
            .replace("\u00d7", "\\327")
            .replace("\u2013", "-")
            .replace("\u2014", "-")
            .replace("\u2212", "-")
            .replace("+", "\\+")
        )

    @classmethod
    def _label(cls, text):
        return cls._ps_escape(text)

    @staticmethod
    def _ps_unescape(text):
        return (
            str(text)
            .replace("\\+", "+")
            .replace("\\260", "\u00b0")
            .replace("\\261", "\u00b1")
            .replace("\\327", "\u00d7")
        )

    DEFAULT_CN_BORDER_DIR = os.path.expanduser("~/.gmt/china-geospatial-data")

    @classmethod
    def find_cn_border_file(cls, variant: str = "l1", explicit_dir: str = "") -> Optional[str]:
        """Locate GMT-China CN-border-L1.gmt or CN-border-La.gmt across standard directories."""
        filename = "CN-border-La.gmt" if variant.lower() == "la" else "CN-border-L1.gmt"
        candidates: List[str] = []
        if explicit_dir:
            exp = os.path.expanduser(explicit_dir.strip())
            candidates.extend([exp, os.path.join(exp, "CN-border")])
        env_dir = os.environ.get("GMT_CN_BORDER_DIR", "").strip()
        if env_dir:
            exp_env = os.path.expanduser(env_dir)
            candidates.extend([exp_env, os.path.join(exp_env, "CN-border")])

        default_dir = cls.DEFAULT_CN_BORDER_DIR
        candidates.append(default_dir)
        if os.path.isdir(default_dir):
            try:
                for entry in sorted(os.listdir(default_dir)):
                    sub = os.path.join(default_dir, entry)
                    if os.path.isdir(sub):
                        candidates.append(sub)
            except OSError:
                pass

        for gmt_sub in ("~/.gmt/server", "~/.gmt/cache", "~/.gmt/userdir"):
            candidates.append(os.path.expanduser(gmt_sub))

        gmt_datadir = os.environ.get("GMT_DATADIR", "")
        for item in gmt_datadir.split(os.pathsep):
            if item.strip():
                candidates.append(os.path.expanduser(item.strip()))

        candidates.append(str(Path(__file__).resolve().parents[1] / "resources" / "cn-border"))

        for directory in candidates:
            probe = os.path.join(directory, filename)
            if os.path.isfile(probe) and os.access(probe, os.R_OK):
                return os.path.abspath(probe)
        return None

    @classmethod
    def cn_border_status(cls, explicit_dir: str = "") -> Dict[str, Any]:
        l1 = cls.find_cn_border_file("l1", explicit_dir)
        la = cls.find_cn_border_file("la", explicit_dir)
        return {
            "installed": bool(l1 or la),
            "l1_path": l1,
            "la_path": la,
            "default_dir": cls.DEFAULT_CN_BORDER_DIR,
        }

    @classmethod
    def install_cn_border_from_zip(cls, zip_path: str, dest_dir: Optional[str] = None) -> Dict[str, Any]:
        """Extract CN-border .gmt files from a local GMT-China archive into ``dest_dir``."""
        import zipfile

        archive_path = os.path.abspath(os.path.expanduser(zip_path))
        if not os.path.isfile(archive_path):
            raise FileNotFoundError(f"CN-border archive not found: {archive_path}")

        target_dir = os.path.abspath(os.path.expanduser(dest_dir or cls.DEFAULT_CN_BORDER_DIR))
        os.makedirs(target_dir, exist_ok=True)

        extracted = 0
        with zipfile.ZipFile(archive_path, "r") as zf:
            for member in zf.infolist():
                if member.is_dir():
                    continue
                base = os.path.basename(member.filename.replace("\\", "/"))
                if not base or not base.endswith(".gmt"):
                    continue
                if base.startswith("CN-border") or base.startswith("ten-dash-line"):
                    dest_file = os.path.join(target_dir, base)
                    with zf.open(member, "r") as src, open(dest_file, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    extracted += 1

        status = cls.cn_border_status(target_dir)
        if extracted == 0 or not status["installed"]:
            raise RuntimeError("Archive did not contain CN-border-L1.gmt or CN-border-La.gmt.")
        return status

    @classmethod
    def download_cn_border_dataset(cls, dest_dir: Optional[str] = None) -> Dict[str, Any]:
        """Download GMT-China china-geospatial-data-UTF8.zip and extract CN-border files."""
        import urllib.request

        target_dir = os.path.abspath(os.path.expanduser(dest_dir or cls.DEFAULT_CN_BORDER_DIR))
        os.makedirs(target_dir, exist_ok=True)

        zip_url = "https://github.com/gmt-china/china-geospatial-data/releases/latest/download/china-geospatial-data-UTF8.zip"
        headers = {"User-Agent": "Graticule/0.6.0"}

        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp_zip:
            tmp_path = tmp_zip.name
        try:
            downloaded = False
            curl_bin = "/usr/bin/curl" if os.path.isfile("/usr/bin/curl") else shutil.which("curl")
            if curl_bin:
                proc = subprocess.run(
                    [curl_bin, "-fsSL", "--connect-timeout", "20", "--max-time", "120", "-o", tmp_path, zip_url],
                    capture_output=True,
                    text=True,
                )
                downloaded = proc.returncode == 0 and os.path.isfile(tmp_path) and os.path.getsize(tmp_path) > 0

            if not downloaded:
                try:
                    req = urllib.request.Request(
                        "https://api.github.com/repos/gmt-china/china-geospatial-data/releases/latest",
                        headers=headers,
                    )
                    with urllib.request.urlopen(req, timeout=20) as resp:
                        release = json.loads(resp.read().decode("utf-8"))
                    for asset in release.get("assets", []):
                        name = str(asset.get("name", ""))
                        if name.endswith("UTF8.zip") and asset.get("browser_download_url"):
                            zip_url = str(asset["browser_download_url"])
                            break
                except Exception:
                    pass

                req = urllib.request.Request(zip_url, headers=headers)
                with urllib.request.urlopen(req, timeout=60) as resp, open(tmp_path, "wb") as out_f:
                    shutil.copyfileobj(resp, out_f)

            return cls.install_cn_border_from_zip(tmp_path, target_dir)
        finally:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass

    def _coast_command(self, config):
        args = ["coast", f"-D{config.coast_resolution}"]
        if config.mask_mode == "land":
            args.append(f"-G{config.mask_color}")
        elif config.mask_mode == "ocean":
            args.append(f"-S{config.mask_color}")
        if config.show_coast:
            args.append(f"-W{config.coast_pen}")
        if config.border_mode in ("gmt_global", "global_cn_l1", "global_cn_la") or (
            config.show_borders and config.border_mode == "none"
        ):
            args.append("-N1/0.4p,gray40")
        args = self._merge_options(args, config.coast_args)
        return args if len(args) > 2 else None

    @staticmethod
    def _settings(config):
        proj_head = (config.projection or "")[:1]
        is_polar_or_azimuthal = proj_head in "SsAaGgEeFf"
        has_north_annot = "N" in (config.frame_sides or "")
        if is_polar_or_azimuthal or has_north_annot:
            title_offset = f"{max(24.0, float(config.annotation_size) + 16.0):g}p"
        else:
            title_offset = "12p"
        conf = {
            "GMT_THEME": "classic", "PROJ_LENGTH_UNIT": "cm", "MAP_FRAME_TYPE": "plain",
            "FONT_TITLE": f"{config.title_size:g}p,Helvetica", "FONT_ANNOT_PRIMARY": f"{config.annotation_size:g}p,Helvetica",
            "FONT_LABEL": f"{config.label_size:g}p,Helvetica", "MAP_TITLE_OFFSET": title_offset,
            "MAP_ANNOT_OFFSET_PRIMARY": "4p", "MAP_LABEL_OFFSET": "6p", "MAP_FRAME_PEN": "0.6p,gray30",
            "MAP_GRID_PEN_PRIMARY": "0.25p,gray65,-", "MAP_TICK_LENGTH_PRIMARY": "3p/1.5p",
            "COLOR_NAN": config.nan_color, "FORMAT_GEO_MAP": "dddF", "PS_MEDIA": "5102x5102",
        }
        conf.update(parse_gmt_conf(config.gmt_conf))
        return conf

    @staticmethod
    def _merge_options(base, extra):
        tokens = shlex.split(extra)
        keys = {a.split("=", 1)[0] if a.startswith("--") else a[:2] for a in tokens if a.startswith("-")}
        kept = [a for a in base if not a.startswith("-") or (a.split("=", 1)[0] if a.startswith("--") else a[:2]) not in keys]
        return kept + tokens

    def _extract_categorical_values(self, config, grid) -> List[float]:
        if config.flag_values:
            out: List[float] = []
            seen = set()
            for v in config.flag_values:
                fv = float(v)
                if math.isfinite(fv) and fv not in seen:
                    seen.add(fv)
                    out.append(fv)
            if out:
                return out[:64]

        file_path, var_name, slice_tuple = self._parse_grid_spec(grid)
        if os.path.isfile(file_path):
            try:
                import netCDF4
                with netCDF4.Dataset(file_path, "r") as ds:
                    vname = var_name or next(
                        (k for k, v in ds.variables.items() if k not in ds.dimensions and v.ndim >= 2),
                        None,
                    )
                    if vname and vname in ds.variables:
                        var = ds.variables[vname]
                        ny, nx = var.shape[-2], var.shape[-1]
                        sy = max(1, ny // 512)
                        sx = max(1, nx // 512)
                        indexer = tuple(slice_tuple) + (slice(None, None, sy), slice(None, None, sx))
                        arr = np.asarray(var[indexer], dtype=np.float64)
                        vals = np.unique(arr[np.isfinite(arr)])
                        del arr
                        if vals.size > 0:
                            return [float(v) for v in vals[:64]]
            except Exception:
                pass

        info = self.get_grid_info(grid, scan=True)
        lo, hi = int(round(info["z_min"])), int(round(info["z_max"]))
        if hi >= lo and (hi - lo) < 64:
            return [float(v) for v in range(lo, hi + 1)]
        raise ValueError("Categorical mode requires CF flag_values or <= 64 distinct discrete values.")

    def _sample_cpt_colors(self, cpt_name: str, count: int, reverse: bool) -> List[Tuple[int, int, int]]:
        n = max(1, count)
        name_low = (cpt_name or "").strip().lower()
        if name_low in ("categorical", "paired", ""):
            base = [self.CATEGORICAL_RGB[i % len(self.CATEGORICAL_RGB)] for i in range(n)]
            return list(reversed(base)) if reverse else base

        try:
            args = ["makecpt", f"-C{cpt_name}", f"-T0/{max(1, n - 1)}/{n}+n", "-Z"]
            if reverse:
                args.append("-Ic")
            out = self._run(args).stdout
            parsed: List[Tuple[int, int, int]] = []
            for raw_line in out.splitlines():
                line = raw_line.strip()
                if not line or line.startswith(("#", "B", "F", "N")):
                    continue
                cols = line.split()
                if len(cols) >= 2 and "/" in cols[1]:
                    rgb = cols[1].split("/")
                    if len(rgb) == 3:
                        parsed.append((int(float(rgb[0])), int(float(rgb[1])), int(float(rgb[2]))))
                elif len(cols) >= 4:
                    parsed.append((int(float(cols[1])), int(float(cols[2])), int(float(cols[3]))))
            if len(parsed) >= n:
                return parsed[:n]
        except Exception:
            pass
        base = [self.CATEGORICAL_RGB[i % len(self.CATEGORICAL_RGB)] for i in range(n)]
        return list(reversed(base)) if reverse else base

    def _categorical_cpt_text(self, config, grid) -> str:
        values = self._extract_categorical_values(config, grid)
        meanings = list(config.flag_meanings or ())
        colors = self._sample_cpt_colors(config.cpt, len(values), config.cpt_reverse)
        use_neutral_zero = (config.cpt or "").strip().lower() in ("categorical", "paired", "")

        lines = ["# COLOR_MODEL = RGB", "# CATEGORICAL"]
        for idx, val in enumerate(values):
            key = str(int(round(val))) if abs(val - round(val)) < 1e-6 else f"{val:g}"
            meaning = meanings[idx].strip() if idx < len(meanings) else ""
            r, g, b = colors[idx]
            if use_neutral_zero and abs(val) < 1e-9 and any(w in meaning.lower() for w in ("land", "none", "nodata", "background")):
                r, g, b = (215, 215, 215)
            if len(values) <= 8 and meaning:
                clean_m = meaning.replace("_", " ")[:14].strip()
                label = f"{key} {clean_m}"
            else:
                label = key
            lines.append(f"{key}\t{r}/{g}/{b}\t;{label}")
        lines.extend(["B\tblack", "F\twhite", f"N\t{config.nan_color}"])
        return "\n".join(lines) + "\n"

    def _commands(self, config, target, fmt, grid=None, cat_cpt_path=None):
        """One command builder serves GUI rendering, CLI and exported scripts."""
        conf = self._settings(config)
        if fmt != "ps": conf["PS_MEDIA"] = "auto"
        cmds = [["begin", target, fmt, f"E{config.dpi}"], ["set", *[x for kv in conf.items() for x in kv]]]
        use_cat = bool(config.cpt_categorical and cat_cpt_path)
        cpt_flag = f"-C{cat_cpt_path}" if use_cat else "-C"
        if not use_cat:
            lo, hi = config.cpt_range
            # Explicit sampling makes continuous (-Z) and discrete modes visibly different.
            count = 257 if config.cpt_continuous else config.cpt_levels+1
            cpt = ["makecpt", f"-C{config.cpt}", "-D", f"-T{lo:.15g}/{hi:.15g}/{count}+n"]
            if config.cpt_continuous:
                cpt.append("-Z")
            if config.cpt_reverse:
                cpt.append("-Ic")
            cpt = self._merge_options(cpt, config.makecpt_args)
            cmds.append(cpt)
        grid = grid or config.grid_spec
        interrupted = config.projection == "IntMollOcean"
        sectors = self.SECTORS if interrupted else [(None, None, config.region, 0, 0)]
        for clon, width, region, ox, oy in sectors:
            proj = f"W{clon}/{width}c" if interrupted else config.projection
            args = ["grdimage", grid, self._region_flag(region), f"-J{proj}", cpt_flag, f"-n{config.interpolation}+c",
                    f"-Xa{5+ox}c", f"-Ya{5+oy}c", f"-E{config.dpi}"]
            extra = shlex.split(config.extra_args)
            custom_frame = any(a.startswith("-B") for a in extra)
            frame_config = config
            if interrupted and config.frame_sides == "WSen":
                frame_config = replace(config, frame_sides=("W" if ox == 0 else "w") + ("en" if oy else "es"))
            if not custom_frame:
                args += self._frame_args(frame_config, title=not interrupted)
            elif config.title and not interrupted and not any("+t" in a for a in extra):
                frame_idx = next((i for i, a in enumerate(extra) if a.startswith("-B") and (len(a) == 2 or a[2] in "WESNwesn+")), None)
                if frame_idx is None: extra.append(f"-B+t{self._label(config.title)}")
                else: extra[frame_idx] += f"+t{self._label(config.title)}"
            args = self._merge_options(args, shlex.join(extra))
            cmds.append(args)
            coast = self._coast_command(config)
            if coast and not config.projection.startswith(("X", "x")):
                cmds.append(coast + [self._region_flag(region), f"-J{proj}", f"-Xa{5+ox}c", f"-Ya{5+oy}c"])
            if not config.projection.startswith(("X", "x")) and config.border_mode in ("cn_l1", "cn_la", "global_cn_l1", "global_cn_la"):
                variant = "la" if config.border_mode.endswith("_la") else "l1"
                border_file = self.find_cn_border_file(variant, config.cn_border_dir)
                if not border_file:
                    raise RuntimeError(
                        "GMT-China CN-border dataset (CN-border-L1.gmt / CN-border-La.gmt) was not found. "
                        "Download it in Inspector or Settings (⌘,) -> Environment."
                    )
                pen = config.border_pen.strip() or "0.5p,gray25"
                cmds.append(["plot", border_file, self._region_flag(region), f"-J{proj}", f"-W{pen}", f"-Xa{5+ox}c", f"-Ya{5+oy}c"])
        if interrupted or (not config.show_frame and config.title and not custom_frame):
            dims = self.get_map_dimensions_cm(config.region, config.projection, config.gmt_conf)
            local_r = f"-R0/{dims[0]}/0/{dims[1]}"
            local_j = f"-JX{dims[0]}c/{dims[1]}c"
            cmds.append(["basemap", local_r, local_j, "-Xa5c", "-Ya5c", "-B+n"])
            if config.title:
                font = self._settings(config)["FONT_TITLE"]
                text = self._ps_escape(config.title)
                cmds.append(["text", local_r, local_j, "-Xa5c", "-Ya5c", "-N", "-D0c/0.35c", f"-F+cTC+f{font}+jBC+t{text}"])
        if config.show_colorbar:
            if use_cat:
                cb_args = ["colorbar", cpt_flag, "-Xa5c", "-Ya5c", "-DJBC+w75%/0.3c+h+o0c/1.1c", "-L"]
                if config.colorbar_title:
                    cb_args.append(f"-Bx+l{self._label(config.colorbar_title)}")
                cb_args.extend([f"--FONT_ANNOT_PRIMARY={config.annotation_size:g}p", f"--FONT_LABEL={config.label_size:g}p"])
                cmds.append(self._merge_options(cb_args, config.colorbar_args))
            else:
                cmds.append(self._merge_options(["colorbar", "-C", "-Xa5c", "-Ya5c", "-DJBC+w70%/0.3c+h+o0c/1.1c", "-Baf" + (f"+l{self._label(config.colorbar_title)}" if config.colorbar_title else ""),
                             f"--FONT_ANNOT_PRIMARY={config.annotation_size:g}p", f"--FONT_LABEL={config.label_size:g}p"], config.colorbar_args))
        cmds.append(["end"])
        return cmds

    @staticmethod
    def _output_spec(path):
        base, ext = os.path.splitext(os.path.abspath(path))
        fmt = ext.lower().lstrip(".")
        fmt = {"jpeg": "jpg", "tiff": "tif"}.get(fmt, fmt)
        if fmt not in ("png", "pdf", "jpg", "svg", "eps", "tif", "ps"):
            raise ValueError("Output requires a supported extension: png, pdf, jpg, svg, eps, tif, ps.")
        return base, fmt

    def render(self, config, output_image_path):
        config = self.resolve_config(config)
        target, fmt = self._output_spec(output_image_path)
        Path(target).parent.mkdir(parents=True, exist_ok=True)
        dims = self.get_map_dimensions_cm(config.region, config.projection, config.gmt_conf)
        if config.preview:
            grid = self._get_or_create_preview_grid(config.grid_spec, config.region)
        else:
            info = self.get_grid_info(config.grid_spec, scan=False)
            if self._estimated_cells(info, config.region) > 25_000_000:
                max_nx = min(6000, max(4000, int(dims[0] / 2.54 * config.dpi * 1.5)))
                max_ny = min(3000, max(2000, int(dims[1] / 2.54 * config.dpi * 1.5)))
                grid = self._get_or_create_preview_grid(
                    config.grid_spec,
                    config.region,
                    max_nx=max_nx,
                    max_ny=max_ny,
                    cell_threshold=25_000_000,
                )
            else:
                grid = config.grid_spec
        render_cfg = config
        if config.preview and config.dpi >= 120:
            if config.projection == "IntMollOcean":
                render_dpi = min(220, max(config.dpi, 180)) if config.dpi <= 220 else config.dpi
            else:
                target_dpi = int(round(2100.0 * 2.54 / max(1.0, max(dims[0], dims[1]))))
                render_dpi = min(300, max(config.dpi, target_dpi))
            if render_dpi != config.dpi:
                render_cfg = replace(config, dpi=render_dpi)
        with tempfile.TemporaryDirectory() as td:
            env = self._env(td)
            if fmt != "ps" and not shutil.which("gs", path=env["PATH"]):
                raise RuntimeError(
                    "Ghostscript (gs) was not found in PATH for psconvert. "
                    "Install Ghostscript (for example via conda/micromamba, Homebrew, or MacPorts) and ensure gs is accessible."
                )
            cat_cpt_path = None
            if render_cfg.cpt_categorical:
                cat_cpt_path = os.path.join(td, "categorical.cpt")
                Path(cat_cpt_path).write_text(self._categorical_cpt_text(render_cfg, grid), encoding="utf-8")
            ps_target = os.path.join(td, "map")
            for args in self._commands(render_cfg, ps_target, "ps", grid, cat_cpt_path=cat_cpt_path):
                res = subprocess.run([self.gmt_bin, *args], cwd=td, env=env, capture_output=True, text=True, timeout=180)
                if res.returncode:
                    raise RuntimeError(f"GMT {args[0]} failed:\n{res.stderr.strip()}")
            psfile = ps_target + ".ps"
            if fmt == "ps":
                shutil.copyfile(psfile, output_image_path)
                return config
            code = {"png": "g", "jpg": "j", "pdf": "f", "eps": "e", "tif": "t", "svg": "f"}[fmt]
            conv_target = os.path.join(td, "converted")
            res = subprocess.run([self.gmt_bin, "psconvert", psfile, "-A", f"-T{code}", f"-E{render_cfg.dpi}", f"-F{conv_target}", "-V"],
                                 cwd=td, env=env, capture_output=True, text=True, timeout=180)
            if res.returncode:
                raise RuntimeError(f"GMT psconvert failed:\n{res.stderr}")
            ext = "pdf" if fmt == "svg" else fmt
            rendered = conv_target + "." + ext
            if fmt == "svg":
                cairo = shutil.which("pdftocairo", path=env["PATH"])
                if not cairo:
                    raise RuntimeError("SVG export requires pdftocairo (Poppler). PDF export is also available.")
                subprocess.run([cairo, "-svg", rendered, conv_target+".svg"], check=True, capture_output=True, timeout=180)
                rendered = conv_target+".svg"
            shutil.copyfile(rendered, output_image_path)
            # psconvert reports the exact crop in points. Origin was fixed at (5,5) cm.
            match = re.search(r"\[([-+\d.eE]+) ([-+\d.eE]+) ([-+\d.eE]+) ([-+\d.eE]+)\]", res.stderr)
            if fmt in ("png", "jpg", "tif") and match:
                xmin, ymin, xmax, ymax = map(float, match.groups())
                scale = render_cfg.dpi/72
                pt = 72/2.54
                bbox = [(5*pt-xmin)*scale, (ymax-(5+dims[1])*pt)*scale,
                        ((5+dims[0])*pt-xmin)*scale, (ymax-5*pt)*scale]
                metadata = {"bbox": bbox, "dims_cm": dims, "config": asdict(config)}
                Path(str(output_image_path)+".map.json").write_text(json.dumps(metadata), encoding="utf-8")
        return config

    def generate_script(self, config, output_filename="output.png"):
        config = self.resolve_config(config)
        _, fmt = self._output_spec(output_filename)
        if fmt == "svg":
            raise ValueError("Standalone GMT scripts support PNG/PDF/EPS/TIFF/JPG/PS. Use --output map.svg for SVG conversion.")
        base = os.path.splitext(output_filename)[0]
        cat_cpt_text = self._categorical_cpt_text(config, config.grid_spec) if config.cpt_categorical else None
        commands = self._commands(config, "__GRATICULE_TARGET__", fmt, cat_cpt_path=("__CAT_CPT__" if cat_cpt_text else None))
        lines = ["#!/usr/bin/env bash", "# Generated by Graticule", "# graticule-config: " + json.dumps(asdict(config)),
                 "set -euo pipefail", 'export GMT_SESSION_NAME="graticule_$$"',
                 'work_dir=$(mktemp -d)', 'trap \'rm -rf "$work_dir"\' EXIT',
                 'export GMT_TMPDIR="$work_dir"', 'export GMT_USERDIR="$work_dir"', ""]
        if cat_cpt_text:
            lines.append("cat <<'GRATICULE_CPT_EOF' > \"$work_dir/categorical.cpt\"")
            lines.extend(cat_cpt_text.rstrip("\n").splitlines())
            lines.append("GRATICULE_CPT_EOF")
            lines.append("")
        lines.extend(
            ("gmt " + shlex.join(args))
            .replace("__GRATICULE_TARGET__", '\"$work_dir/map\"')
            .replace("__CAT_CPT__", '\"$work_dir/categorical.cpt\"')
            for args in commands
        )
        parent = os.path.dirname(output_filename) or "."
        lines += ["mkdir -p -- " + shlex.quote(parent), 'cp -- "$work_dir/map.' + fmt + '" ' + shlex.quote(output_filename)]
        return "\n".join(lines)+"\n"

    @classmethod
    def parse_script_to_config(cls, script_text, fallback_config):
        """Read supported GMT plot parameters without evaluating any shell code."""
        config = replace(fallback_config, slice_indices=dict(fallback_config.slice_indices))
        commands = []
        for line in script_text.replace("\\\n", " ").splitlines():
            if line.startswith("# graticule-config: ") or line.startswith("# graticule-config: "):
                try:
                    config = PlotConfig(**json.loads(line.split(": ", 1)[1]))
                except (TypeError, ValueError) as exc:
                    raise ValueError(f"Invalid plot metadata: {exc}") from exc
            try:
                parts = shlex.split(line, comments=True)
            except ValueError as exc:
                raise ValueError(f"Cannot parse script: {exc}") from exc
            if len(parts) > 1 and os.path.basename(parts[0]) == "gmt":
                commands.append(parts[1:])
        baseline_settings = cls._settings(config)
        if any(a[0] == "begin" and len(a) > 2 and a[2] != "ps" for a in commands): baseline_settings["PS_MEDIA"] = "auto"
        custom_settings = parse_gmt_conf(config.gmt_conf)
        grids = [a for a in commands if a[0] == "grdimage"]
        if not grids: raise ValueError("No GMT grdimage command was found to synchronize.")
        interrupted = len(grids) == 6 and any("-JW60/9c" in a for a in grids)
        settings = {}
        config.show_colorbar = any(a[0] == "colorbar" for a in commands)
        config.show_coast = config.show_borders = False
        config.border_mode = "none"
        config.mask_mode = "none"
        has_global_n = False
        cn_variant = None
        for args in commands:
            module = args[0]
            if module == "set":
                settings.update(zip(args[1::2], args[2::2]))
            elif module == "begin":
                for a in args[2:]:
                    if a.startswith("E") and a[1:].isdigit(): config.dpi = int(a[1:])
            elif module == "makecpt":
                config.cpt_continuous = "-Z" in args
                config.cpt_reverse = any(a in ("-I", "-Ic") for a in args)
                extra = []
                for a in args[1:]:
                    if a.startswith("-C"): config.cpt = a[2:]
                    elif a.startswith("-T"):
                        vals = a[2:].split("/")
                        config.cpt_range = tuple(map(float, vals[:2]))
                        if not config.cpt_continuous and len(vals) == 3:
                            config.cpt_levels = int(float(vals[2][:-2]))-1 if vals[2].endswith("+n") else round((config.cpt_range[1]-config.cpt_range[0])/float(vals[2]))
                    elif a not in ("-D", "-Z", "-I", "-Ic"): extra.append(a)
                config.makecpt_args = shlex.join(extra)
            elif module == "grdimage" and args is grids[0]:
                old_proj = config.projection
                old_region = config.region
                config.show_frame = False
                config.show_grid = False
                config.title = ""
                extra = []
                for a in args[2:]:
                    if a.startswith("-J"): config.projection = a[2:]
                    elif a.startswith("-R"): config.region = tuple(map(float, a[2:].split("/")))
                    elif a.startswith("-n"): config.interpolation = a[2]
                    elif a.startswith(("-X", "-Y", "-E", "-C")): continue
                    elif a.startswith("-B"):
                        if "+t" in a: config.title = cls._ps_unescape(a.split("+t", 1)[1])
                        frame = a[2:].split("+", 1)[0]
                        axis = re.fullmatch(r"([xy])a([\d.eE+-]*)f(?:g([\d.eE+-]*))?", frame)
                        if axis:
                            setattr(config, "x_interval" if axis[1] == "x" else "y_interval", float(axis[2]) if axis[2] else 0)
                            config.show_grid = config.show_grid or "g" in frame
                            config.show_frame = True
                        elif re.fullmatch(r"[WESNwesn]+", frame):
                            config.frame_sides = frame; config.show_frame = True
                        elif frame in ("af", "afg"):
                            config.show_frame = True; config.show_grid = "g" in frame
                        elif a.startswith("-B+n"): config.show_frame = False
                        elif a.startswith("-B+t"): pass
                        else: extra.append(a); config.show_frame = True
                    else: extra.append(a)
                config.extra_args = shlex.join(extra)
                if old_proj != config.projection: config.projection_mode = "manual"
                if interrupted:
                    config.projection = "IntMollOcean"; config.region = old_region
            elif module == "coast":
                extra = []
                for a in args[1:]:
                    if a.startswith("-W"): config.show_coast = True; config.coast_pen = a[2:]
                    elif a.startswith("-N"): has_global_n = True
                    elif a.startswith("-G"): config.mask_mode = "land"; config.mask_color = a[2:]
                    elif a.startswith("-S"): config.mask_mode = "ocean"; config.mask_color = a[2:]
                    elif a.startswith("-D"): config.coast_resolution = a[2:]
                    elif not a.startswith(("-R", "-J", "-X", "-Y")): extra.append(a)
                config.coast_args = shlex.join(extra)
            elif module == "plot":
                for a in args[1:]:
                    if a.startswith("-W") and len(a) > 2:
                        config.border_pen = a[2:]
                    elif not a.startswith("-"):
                        base = os.path.basename(a)
                        if base == "CN-border-L1.gmt":
                            cn_variant = "l1"
                        elif base == "CN-border-La.gmt":
                            cn_variant = "la"
            elif module == "colorbar":
                extra = []
                for a in args[1:]:
                    if a.startswith("-Baf"):
                        config.colorbar_title = cls._ps_unescape(a.split("+l", 1)[1]) if "+l" in a else ""
                    elif a in ("-C", "-Xa5c", "-Ya5c", "-DJBC+w70%/0.3c+h+o0c/1.1c", f"--FONT_ANNOT_PRIMARY={config.annotation_size:g}p", f"--FONT_LABEL={config.label_size:g}p"): continue
                    else: extra.append(a)
                config.colorbar_args = shlex.join(extra)
            elif module in ("basemap", "text") and (interrupted or not config.show_frame):
                for a in args:
                    if "+t" in a: config.title = cls._ps_unescape(a.split("+t", 1)[1])
        if interrupted:
            # The overall projection is a layout; sector frame choices are internal.
            config.projection = "IntMollOcean"
            config.frame_sides = fallback_config.frame_sides
            config.projection_mode = fallback_config.projection_mode
        if has_global_n and cn_variant == "la":
            config.border_mode = "global_cn_la"
        elif has_global_n and cn_variant == "l1":
            config.border_mode = "global_cn_l1"
        elif cn_variant == "la":
            config.border_mode = "cn_la"
        elif cn_variant == "l1":
            config.border_mode = "cn_l1"
        elif has_global_n:
            config.border_mode = "gmt_global"
        else:
            config.border_mode = "none"
        config.show_borders = has_global_n
        for key, value in settings.items():
            if value == baseline_settings.get(key): continue
            if key in ("FONT_TITLE", "FONT_ANNOT_PRIMARY", "FONT_LABEL"):
                field_name = {"FONT_TITLE":"title_size", "FONT_ANNOT_PRIMARY":"annotation_size", "FONT_LABEL":"label_size"}[key]
                match = re.match(r"([\d.]+)p(?:,Helvetica)?$", value)
                if match:
                    setattr(config, field_name, float(match.group(1))); custom_settings.pop(key, None)
                else: custom_settings[key] = value
            elif key == "COLOR_NAN": config.nan_color = value
            else: custom_settings[key] = value
        config.gmt_conf = ", ".join(f"{k}={v}" for k, v in custom_settings.items())
        config.validate()
        return config
