"""
Cached NumPy .npz to CF NetCDF4 converter for Graticule.

Converts `.npz` archives into temporary CF-1.7 NetCDF4 files keyed by
(abspath, mtime_ns, size) so GMT 6 and xarray can inspect and render any
2D+ numeric arrays inside `.npz` files without duplicating conversion work.
"""

from collections import OrderedDict
import atexit
import gc
import hashlib
import os
import tempfile
import threading
from typing import Dict, List, Optional, Tuple

import netCDF4
import numpy as np


_CACHE_LOCK = threading.RLock()
_CACHE_DIR = os.path.join(tempfile.gettempdir(), "graticule_npz_cache")
_CREATED_FILES: "OrderedDict[str, str]" = OrderedDict()
_MAX_CACHE_ENTRIES = 16

_X_NAMES = {"lon", "longitude", "x", "glon", "xdim", "rlon"}
_Y_NAMES = {"lat", "latitude", "y", "glat", "ydim", "rlat"}
_GEO_X_NAMES = {"lon", "longitude", "glon", "rlon"}
_GEO_Y_NAMES = {"lat", "latitude", "glat", "rlat"}


def is_npz_path(file_path: str) -> bool:
    return file_path.lower().endswith(".npz")


def _cleanup_cache() -> None:
    with _CACHE_LOCK:
        for path in list(_CREATED_FILES.values()):
            try:
                os.unlink(path)
            except OSError:
                pass
        _CREATED_FILES.clear()


atexit.register(_cleanup_cache)


def _target_netcdf_dtype(arr: np.ndarray) -> np.dtype:
    dt = np.dtype(arr.dtype)
    if dt in (np.dtype("float32"), np.dtype("float64")):
        return dt
    if dt in (np.dtype("int32"), np.dtype("uint32"), np.dtype("int64"), np.dtype("uint64")):
        return np.dtype("float64")
    return np.dtype("float32")


def _sanitize_nc_name(raw_name: str, used: set) -> str:
    cleaned = "".join(ch if (ch.isalnum() or ch in ("_", "-", ".")) else "_" for ch in str(raw_name)).strip("_")
    if not cleaned or not (cleaned[0].isalpha() or cleaned[0] == "_"):
        cleaned = "var_" + (cleaned or "0")
    candidate = cleaned
    suffix = 1
    while candidate in used:
        candidate = f"{cleaned}_{suffix}"
        suffix += 1
    used.add(candidate)
    return candidate


def _extract_1d_coordinates(archive) -> Tuple[Dict[str, Tuple[np.ndarray, str]], set]:
    """Return discovered spatial/slice 1D coordinate vectors and consumed coordinate keys."""
    coords: Dict[str, Tuple[np.ndarray, str]] = {}
    consumed: set = set()

    for key in archive.files:
        arr = archive[key]
        if arr.ndim == 1 and arr.size >= 2 and np.issubdtype(arr.dtype, np.number):
            low = key.lower()
            kind = "x" if low in _X_NAMES else ("y" if low in _Y_NAMES else "other")
            coords[key] = (np.asarray(arr, dtype=np.float64), kind)
            consumed.add(key)

    # Also detect 2D uniform meshgrid coordinate arrays (e.g. lon/lat grids).
    for key in archive.files:
        if key in consumed:
            continue
        arr = archive[key]
        if arr.ndim != 2 or min(arr.shape) < 2 or not np.issubdtype(arr.dtype, np.number):
            continue
        low = key.lower()
        if low in _X_NAMES and np.allclose(arr, arr[0:1, :], equal_nan=True):
            coords[key] = (np.asarray(arr[0, :], dtype=np.float64), "x")
            consumed.add(key)
        elif low in _Y_NAMES and np.allclose(arr, arr[:, 0:1], equal_nan=True):
            coords[key] = (np.asarray(arr[:, 0], dtype=np.float64), "y")
            consumed.add(key)

    return coords, consumed


def _pick_coordinate(
    coords: Dict[str, Tuple[np.ndarray, str]],
    target_len: int,
    preferred_kind: str,
    exclude_names: set,
) -> Optional[Tuple[str, np.ndarray]]:
    exact = [
        (name, vec)
        for name, (vec, kind) in coords.items()
        if name not in exclude_names and kind == preferred_kind and vec.size == target_len
    ]
    if len(exact) == 1:
        return exact[0]
    if preferred_kind == "other" and len(exact) > 1:
        return exact[0]
    return None


def _convert_npz_to_nc(abs_npz_path: str, target_nc_path: str) -> None:
    try:
        archive = np.load(abs_npz_path, allow_pickle=False)
    except ValueError as exc:
        raise ValueError(
            f"Cannot safely open {os.path.basename(abs_npz_path)}: archive contains pickled Python objects."
        ) from exc

    fd, tmp_path = tempfile.mkstemp(prefix="tmp_npz_", suffix=".nc", dir=os.path.dirname(target_nc_path))
    os.close(fd)

    try:
        with archive:
            coords, consumed_keys = _extract_1d_coordinates(archive)
            used_names: set = set()
            plottable_keys = [
                k for k in archive.files
                if k not in consumed_keys
                and archive[k].ndim >= 2
                and (np.issubdtype(archive[k].dtype, np.number) or archive[k].dtype == np.bool_)
            ]
            if not plottable_keys:
                raise ValueError(
                    f"NPZ archive {os.path.basename(abs_npz_path)} contains no plottable 2D+ numeric arrays."
                )

            with netCDF4.Dataset(tmp_path, "w", format="NETCDF4") as ds:
                ds.Conventions = "CF-1.7"
                ds.source_npz = abs_npz_path
                ds.source_format = "numpy_npz"

                for key in archive.files:
                    arr = archive[key]
                    if arr.ndim == 0:
                        attr_name = _sanitize_nc_name(f"npz_{key}", used=set())
                        val = arr.item()
                        if isinstance(val, (np.floating, np.integer, np.bool_)):
                            val = val.item()
                        setattr(ds, attr_name, val if isinstance(val, (int, float, str)) else str(val))

                def ensure_axis_dim(dim_name: str, values: np.ndarray, axis_letter: Optional[str], is_geo: bool) -> str:
                    if dim_name in ds.dimensions:
                        return dim_name
                    used_names.add(dim_name)
                    ds.createDimension(dim_name, values.size)
                    dtype_code = "f8" if np.issubdtype(values.dtype, np.floating) else "i8"
                    cvar = ds.createVariable(dim_name, dtype_code, (dim_name,))
                    cvar[:] = values
                    if axis_letter == "X":
                        cvar.axis = "X"
                        if is_geo:
                            cvar.standard_name = "longitude"
                            cvar.units = "degrees_east"
                    elif axis_letter == "Y":
                        cvar.axis = "Y"
                        if is_geo:
                            cvar.standard_name = "latitude"
                            cvar.units = "degrees_north"
                    return dim_name

                for key in plottable_keys:
                    arr = archive[key]
                    shape = arr.shape
                    ny, nx = shape[-2], shape[-1]

                    picked_x = _pick_coordinate(coords, nx, "x", set())
                    picked_y = _pick_coordinate(coords, ny, "y", {picked_x[0]} if picked_x else set())

                    if picked_x is not None:
                        x_dim = ensure_axis_dim(
                            picked_x[0],
                            picked_x[1],
                            "X",
                            picked_x[0].lower() in _GEO_X_NAMES,
                        )
                    else:
                        x_dim = ensure_axis_dim(f"x_{nx}", np.arange(nx, dtype=np.float64), "X", False)

                    if picked_y is not None:
                        y_dim = ensure_axis_dim(
                            picked_y[0],
                            picked_y[1],
                            "Y",
                            picked_y[0].lower() in _GEO_Y_NAMES,
                        )
                    else:
                        y_dim = ensure_axis_dim(f"y_{ny}", np.arange(ny, dtype=np.float64), "Y", False)

                    leading_dims: List[str] = []
                    used_leading = {x_dim, y_dim}
                    for axis_idx, length in enumerate(shape[:-2]):
                        picked_lead = _pick_coordinate(coords, length, "other", used_leading)
                        if picked_lead is not None:
                            ld = ensure_axis_dim(picked_lead[0], picked_lead[1], None, False)
                        else:
                            ld = ensure_axis_dim(f"dim{axis_idx}_{length}", np.arange(length, dtype=np.int64), None, False)
                        leading_dims.append(ld)
                        used_leading.add(ld)

                    var_name = _sanitize_nc_name(key, used_names)
                    out_dtype = _target_netcdf_dtype(arr)
                    nc_type = "f4" if out_dtype == np.dtype("float32") else "f8"
                    dims_tuple = tuple(leading_dims + [y_dim, x_dim])

                    out_var = ds.createVariable(var_name, nc_type, dims_tuple, fill_value=np.nan)
                    casted = np.asarray(arr, dtype=out_dtype)
                    out_var[:] = casted
                    out_var.long_name = str(key)
                    out_var.original_dtype = str(arr.dtype)

                    if np.issubdtype(casted.dtype, np.floating):
                        finite = np.isfinite(casted)
                        if finite.any():
                            vmin = float(np.min(casted[finite]))
                            vmax = float(np.max(casted[finite]))
                            out_var.actual_range = [vmin, vmax]

                    del casted

        gc.collect()
        os.replace(tmp_path, target_nc_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def resolve_nc_path(file_path: str) -> str:
    """Return a NetCDF path readable by xarray/GMT, converting `.npz` via cache if needed."""
    abs_path = os.path.abspath(file_path)
    if not is_npz_path(abs_path):
        return abs_path
    if not os.path.isfile(abs_path):
        raise FileNotFoundError(f"File not found: {abs_path}")

    stat = os.stat(abs_path)
    digest = hashlib.sha256(f"{abs_path}|{stat.st_mtime_ns}|{stat.st_size}".encode("utf-8")).hexdigest()[:24]
    cached_nc = os.path.join(_CACHE_DIR, f"graticule_{digest}.nc")

    with _CACHE_LOCK:
        if os.path.isfile(cached_nc):
            _CREATED_FILES[digest] = cached_nc
            _CREATED_FILES.move_to_end(digest)
            return cached_nc

        os.makedirs(_CACHE_DIR, exist_ok=True)
        _convert_npz_to_nc(abs_path, cached_nc)
        _CREATED_FILES[digest] = cached_nc
        _CREATED_FILES.move_to_end(digest)
        while len(_CREATED_FILES) > _MAX_CACHE_ENTRIES:
            _, evicted = _CREATED_FILES.popitem(last=False)
            if evicted != cached_nc:
                try:
                    os.unlink(evicted)
                except OSError:
                    pass
        return cached_nc
