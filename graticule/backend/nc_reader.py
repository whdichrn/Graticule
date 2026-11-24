"""
NetCDF Metadata Reader.
Parses file metadata, dimensions, coordinates, and variables lazily without loading full data arrays into memory.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Any
import os
import xarray as xr
import numpy as np


@dataclass
class VarMeta:
    name: str
    dimensions: List[str]
    shape: Tuple[int, ...]
    dtype: str
    attrs: Dict[str, Any] = field(default_factory=dict)
    is_2d_plotable: bool = False

    # Identified axis dimensions
    x_dim: Optional[str] = None
    y_dim: Optional[str] = None
    slice_dims: List[str] = field(default_factory=list)  # Extra dimensions like time, level

    is_geographic: bool = True
    unsupported_reason: str = ""

    # Coordinate ranges [min, max]
    x_range: Optional[Tuple[float, float]] = None
    y_range: Optional[Tuple[float, float]] = None
    v_range: Optional[Tuple[float, float]] = None

    @property
    def display_title(self) -> str:
        long_name = self.attrs.get("long_name") or self.attrs.get("standard_name") or self.name
        units = self.attrs.get("units")
        if units:
            return f"{long_name} ({units})"
        return str(long_name)


@dataclass
class DatasetMeta:
    file_path: str
    dimensions: Dict[str, int]
    dimension_coords: Dict[str, List[Any]]  # Coordinates values for sliders (e.g. time strings, levels)
    variables: Dict[str, VarMeta]
    global_attrs: Dict[str, Any]


class NetCDFMetadataReader:
    """Reads NetCDF metadata with lazy evaluation."""

    # Common coordinate keywords for geographic / cartesian identification
    X_KEYWORDS = {"lon", "longitude", "x", "glon", "xdim", "rlon"}
    Y_KEYWORDS = {"lat", "latitude", "y", "glat", "ydim", "rlat"}

    @classmethod
    def open(cls, file_path: str) -> DatasetMeta:
        """Opens a NetCDF dataset and extracts metadata without reading data arrays."""
        if not os.path.exists(file_path):
            raise FileNotFoundError(f"File not found: {file_path}")

        # Open lazily without decoding timedelta if not needed, engine='netcdf4'
        ds = xr.open_dataset(file_path, decode_times=True)
        try:
            dimensions = {str(k): int(v) for k, v in ds.sizes.items()}

            # Spatial coordinate arrays are not copied into millions of Python objects.
            slice_names = set()
            for da in ds.data_vars.values():
                if da.ndim >= 2:
                    slice_names.update(cls._identify_axes(list(da.dims), ds)[2])

            # Extract only slice coordinates used by sliders
            dim_coords: Dict[str, List[Any]] = {}
            for dim_name in slice_names:
                if dim_name in ds.coords:
                    coord_vals = ds.coords[dim_name].isel({dim_name: slice(0, 10000)}).values
                    # If time or datetime, format to readable string
                    if np.issubdtype(coord_vals.dtype, np.datetime64):
                        dim_coords[dim_name] = [str(t)[:19] for t in coord_vals]
                    else:
                        dim_coords[dim_name] = [
                            float(x) if isinstance(x, (np.floating, float)) else str(x)
                            for x in coord_vals
                        ]
                else:
                    dim_coords[dim_name] = list(range(min(10000, dimensions[dim_name])))

            variables: Dict[str, VarMeta] = {}

            # Process all data variables and coordinates that have 2D+ dimensions
            all_candidate_vars = list(ds.data_vars.items()) + [
                (k, v) for k, v in ds.coords.items() if v.ndim >= 2
            ]

            for var_name, da in all_candidate_vars:
                shape = tuple(da.shape)
                dims = [str(d) for d in da.dims]
                attrs = dict(da.attrs)

                # Check if it's 2D or higher dimension (eligible for 2D map plot)
                is_2d_plotable = len(shape) >= 2 and np.issubdtype(da.dtype, np.number)

                x_dim, y_dim, slice_dims = cls._identify_axes(dims, ds)
                x_range = None
                y_range = None

                if x_dim and x_dim in ds.coords:
                    x_vals = ds.coords[x_dim].values
                    if len(x_vals) > 0 and np.issubdtype(x_vals.dtype, np.number):
                        x_range = (float(np.nanmin(x_vals)), float(np.nanmax(x_vals)))

                if y_dim and y_dim in ds.coords:
                    y_vals = ds.coords[y_dim].values
                    if len(y_vals) > 0 and np.issubdtype(y_vals.dtype, np.number):
                        y_range = (float(np.nanmin(y_vals)), float(np.nanmax(y_vals)))

                unsupported_reason = ""
                if is_2d_plotable:
                    if dims[-2:] != [y_dim, x_dim]:
                        unsupported_reason = "GMT needs the last two dimensions in Y, X order. Transpose this variable before plotting."
                    for axis in (x_dim, y_dim):
                        if axis in ds.coords:
                            vals = np.asarray(ds.coords[axis].values)
                            if vals.ndim != 1 or not np.issubdtype(vals.dtype, np.number) or vals.size < 2:
                                unsupported_reason = "GMT requires one-dimensional numeric spatial coordinates with at least two points."
                            elif not np.isfinite(vals).all() or not np.allclose(np.diff(vals), np.diff(vals)[0], rtol=1e-4, atol=max(1e-8, np.finfo(vals.dtype).eps * max(1.0, float(np.max(np.abs(vals))))*4) if np.issubdtype(vals.dtype, np.floating) else 1e-8):
                                unsupported_reason = "Irregular or curvilinear coordinates need regridding before GMT plotting."
                    # A 2D auxiliary lon/lat coordinate means index axes are not geographic.
                    if any(c.ndim == 2 and str(c.attrs.get("standard_name", c.name)).lower() in ("longitude", "latitude", "lon", "lat") for c in da.coords.values()):
                        unsupported_reason = "Curvilinear coordinates need regridding before GMT plotting."
                if unsupported_reason:
                    is_2d_plotable = False
                x_units = str(ds[x_dim].attrs.get("units", "")).lower() if x_dim in ds else ""
                y_units = str(ds[y_dim].attrs.get("units", "")).lower() if y_dim in ds else ""
                is_geographic = bool((x_dim and x_dim.lower() in {"lon", "longitude", "glon"}) or
                                     ("degree" in x_units and "degree" in y_units))
                if x_dim and x_range is None and dimensions[x_dim] > 1:
                    x_range = (0.0, float(dimensions[x_dim]-1))
                if y_dim and y_range is None and dimensions[y_dim] > 1:
                    y_range = (0.0, float(dimensions[y_dim]-1))

                # Check for explicit valid_range or actual_range in attributes
                v_range = None
                if "valid_range" in attrs:
                    try:
                        v_range = (float(attrs["valid_range"][0]), float(attrs["valid_range"][1]))
                    except Exception:
                        pass
                elif "actual_range" in attrs:
                    try:
                        v_range = (float(attrs["actual_range"][0]), float(attrs["actual_range"][1]))
                    except Exception:
                        pass

                var_meta = VarMeta(
                    name=str(var_name),
                    dimensions=dims,
                    shape=shape,
                    dtype=str(da.dtype),
                    attrs=attrs,
                    is_2d_plotable=is_2d_plotable,
                    x_dim=x_dim,
                    y_dim=y_dim,
                    slice_dims=slice_dims,
                    x_range=x_range,
                    y_range=y_range,
                    v_range=v_range,
                    is_geographic=is_geographic,
                    unsupported_reason=unsupported_reason
                )
                variables[str(var_name)] = var_meta

            global_attrs = dict(ds.attrs)

            return DatasetMeta(
                file_path=os.path.abspath(file_path),
                dimensions=dimensions,
                dimension_coords=dim_coords,
                variables=variables,
                global_attrs=global_attrs
            )
        finally:
            ds.close()

    @classmethod
    def _identify_axes(cls, dims: List[str], ds=None) -> Tuple[Optional[str], Optional[str], List[str]]:
        """Prefer CF axis attributes, then exact names; never match 'x' in 'depth'."""
        if len(dims) < 2:
            return None, None, dims
        x_dim = y_dim = None
        for d in dims:
            attrs = ds[d].attrs if ds is not None and d in ds else {}
            axis = str(attrs.get("axis", "")).upper()
            standard = str(attrs.get("standard_name", "")).lower()
            units = str(attrs.get("units", "")).lower()
            if axis == "X" or standard in ("longitude", "projection_x_coordinate") or "degrees_east" in units:
                x_dim = d
            if axis == "Y" or standard in ("latitude", "projection_y_coordinate") or "degrees_north" in units:
                y_dim = d
        x_dim = x_dim or next((d for d in reversed(dims) if d.lower() in cls.X_KEYWORDS), None)
        y_dim = y_dim or next((d for d in reversed(dims) if d.lower() in cls.Y_KEYWORDS and d != x_dim), None)
        x_dim = x_dim or next(d for d in reversed(dims) if d != y_dim)
        y_dim = y_dim or next(d for d in reversed(dims) if d != x_dim)
        return x_dim, y_dim, [d for d in dims if d not in (x_dim, y_dim)]

    @staticmethod
    def build_gmt_grid_spec(file_path: str, var_meta: VarMeta, slice_indices: Dict[str, int]) -> str:
        """GMT indexes leading non-spatial dimensions only, e.g. ?temp[2,1]."""
        if not var_meta.is_2d_plotable:
            raise ValueError(var_meta.unsupported_reason or "Select a numeric 2D grid variable.")
        unknown = set(slice_indices)-set(var_meta.slice_dims)
        if unknown:
            raise ValueError(f"Unknown slice dimensions: {', '.join(sorted(unknown))}")
        indices = []
        for dim in var_meta.slice_dims:
            index = slice_indices.get(dim, 0)
            size = var_meta.shape[var_meta.dimensions.index(dim)]
            if not isinstance(index, int) or not 0 <= index < size:
                raise ValueError(f"Slice {dim}={index} is outside 0..{size-1}.")
            indices.append(str(index))
        suffix = "["+",".join(indices)+"]" if indices else ""
        return f"{os.path.abspath(file_path)}?{var_meta.name}{suffix}"
