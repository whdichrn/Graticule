"""Persistent NDJSON JSON-RPC server for the native macOS SwiftUI frontend."""

import sys

# Protect the RPC stdout channel from stray prints inside third-party libraries.
_RPC_OUT = sys.stdout
sys.stdout = sys.stderr

import base64
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
import gc
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import traceback
from typing import Any, Dict, Optional, Tuple
import uuid

import numpy as np

from .gmt_engine import GMTEngine, PlotConfig
from .nc_reader import DatasetMeta, NetCDFMetadataReader

SERVER_VERSION = "0.7.0"
HOVER_GRID_SIZE = 65
PREVIEW_CACHE_LIMIT = 24
DATASET_CACHE_LIMIT = 32


def _cleanup_stale_temp_dirs(max_age_sec: float = 86400.0) -> None:
    """Best-effort cleanup for orphaned RPC temp dirs left by instant termination."""
    tmp_root = tempfile.gettempdir()
    now = time.time()
    try:
        entries = os.listdir(tmp_root)
    except OSError:
        return
    for name in entries:
        if not name.startswith("graticule_rpc_"):
            continue
        full = os.path.join(tmp_root, name)
        try:
            st = os.stat(full)
            if now - st.st_mtime >= max_age_sec:
                shutil.rmtree(full, ignore_errors=True)
        except OSError:
            pass


def _to_json_safe(value: Any) -> Any:
    """Recursively convert NumPy/NetCDF scalars and containers into JSON-safe Python primitives."""
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return value if np.isfinite(value) else None
    if isinstance(value, np.bool_):
        return bool(value)
    if isinstance(value, np.integer):
        return int(value)
    if isinstance(value, np.floating):
        fval = float(value)
        return fval if np.isfinite(fval) else None
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    if isinstance(value, np.ndarray):
        return [_to_json_safe(item) for item in value.tolist()]
    if isinstance(value, (list, tuple)):
        return [_to_json_safe(item) for item in value]
    if isinstance(value, dict):
        return {str(k): _to_json_safe(v) for k, v in value.items()}
    return str(value)


def _plot_config_from_dict(data: Dict[str, Any], meta: Optional[DatasetMeta] = None) -> PlotConfig:
    """Construct a PlotConfig from a JSON dict, filling grid_spec if omitted."""
    raw = dict(data)
    region = raw.get("region")
    if region is not None:
        region = tuple(float(x) for x in region)
    cpt_range = raw.get("cpt_range")
    if cpt_range is not None:
        cpt_range = tuple(float(x) for x in cpt_range)
    slice_indices = {str(k): int(v) for k, v in (raw.get("slice_indices") or {}).items()}

    grid_spec = str(raw.get("grid_spec") or "")
    source_path = str(raw.get("source_path") or "")
    variable_name = str(raw.get("variable_name") or "")
    if not grid_spec and meta is not None and variable_name in meta.variables:
        grid_spec = NetCDFMetadataReader.build_gmt_grid_spec(
            meta.file_path, meta.variables[variable_name], slice_indices
        )

    return PlotConfig(
        grid_spec=grid_spec,
        region=region,
        projection=str(raw.get("projection", "Q16c")),
        cpt=str(raw.get("cpt", "rainbow")),
        cpt_range=cpt_range,
        cpt_reverse=bool(raw.get("cpt_reverse", False)),
        cpt_continuous=bool(raw.get("cpt_continuous", True)),
        mask_mode=str(raw.get("mask_mode", "none")),
        mask_color=str(raw.get("mask_color", "gray90")),
        show_coast=bool(raw.get("show_coast", True)),
        show_borders=bool(raw.get("show_borders", False)),
        show_grid=bool(raw.get("show_grid", True)),
        show_colorbar=bool(raw.get("show_colorbar", True)),
        colorbar_title=str(raw.get("colorbar_title", "")),
        dpi=int(raw.get("dpi", 150)),
        title=str(raw.get("title", "")),
        extra_args=str(raw.get("extra_args", "")),
        gmt_conf=str(raw.get("gmt_conf", "")),
        projection_mode=str(raw.get("projection_mode", "manual")),
        is_geographic=bool(raw.get("is_geographic", True)),
        source_path=source_path,
        variable_name=variable_name,
        variable_description=str(raw.get("variable_description", "")),
        slice_indices=slice_indices,
        show_frame=bool(raw.get("show_frame", True)),
        frame_sides=str(raw.get("frame_sides", "WSen")),
        x_interval=float(raw.get("x_interval", 0.0)),
        y_interval=float(raw.get("y_interval", 0.0)),
        title_size=float(raw.get("title_size", 14.0)),
        annotation_size=float(raw.get("annotation_size", 10.0)),
        label_size=float(raw.get("label_size", 11.0)),
        symmetric_cpt=bool(raw.get("symmetric_cpt", False)),
        cpt_levels=int(raw.get("cpt_levels", 16)),
        cpt_categorical=bool(raw.get("cpt_categorical", False)),
        flag_values=tuple(float(x) for x in (raw.get("flag_values") or ())),
        flag_meanings=tuple(str(x) for x in (raw.get("flag_meanings") or ())),
        coast_resolution=str(raw.get("coast_resolution", "l")),
        coast_pen=str(raw.get("coast_pen", "0.4p,gray25")),
        interpolation=str(raw.get("interpolation", "c")),
        nan_color=str(raw.get("nan_color", "gray90")),
        preview=bool(raw.get("preview", False)),
        makecpt_args=str(raw.get("makecpt_args", "")),
        coast_args=str(raw.get("coast_args", "")),
        colorbar_args=str(raw.get("colorbar_args", "")),
        border_mode=str(raw.get("border_mode", "none")),
        border_pen=str(raw.get("border_pen", "0.5p,gray25")),
        cn_border_dir=str(raw.get("cn_border_dir", "")),
    )


def _plot_config_to_dict(cfg: PlotConfig) -> Dict[str, Any]:
    return _to_json_safe(asdict(cfg))


class RPCServer:
    """Line-delimited JSON-RPC server wrapping NetCDFMetadataReader and GMTEngine."""

    FAST_METHODS = frozenset({
        "ping",
        "open_dataset",
        "recommend_projections",
        "get_cpt_options",
        "generate_script",
        "parse_script",
        "selection_region",
        "cn_border_status",
    })
    HEAVY_METHODS = frozenset({
        "render",
        "scan_range",
        "run_script",
        "install_cn_border",
    })

    def __init__(self, out_stream=None):
        self._out = out_stream or _RPC_OUT
        self._write_lock = threading.Lock()
        self._state_lock = threading.RLock()
        self._engine: Optional[GMTEngine] = None
        _cleanup_stale_temp_dirs()
        self._temp_owner = tempfile.TemporaryDirectory(prefix="graticule_rpc_")
        self._preview_cache: OrderedDict[str, str] = OrderedDict()
        self._dataset_cache: OrderedDict[Tuple[str, int, int], DatasetMeta] = OrderedDict()
        self._fast_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="rpc-fast")
        # Strictly single-worker heavy lane prevents concurrent GMT memory spikes.
        self._heavy_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="rpc-gmt")
        self._stop_event = threading.Event()
        self._pending_futures = set()

    def _get_engine(self) -> GMTEngine:
        with self._state_lock:
            if self._engine is None:
                self._engine = GMTEngine()
            return self._engine

    def _get_dataset_meta(self, path: str) -> DatasetMeta:
        if not os.path.exists(path):
            raise FileNotFoundError(f"File not found: {path}")
        real = os.path.realpath(path)
        st = os.stat(real)
        key = (real, st.st_mtime_ns, st.st_size)
        with self._state_lock:
            if key in self._dataset_cache:
                self._dataset_cache.move_to_end(key)
                return self._dataset_cache[key]
        meta = NetCDFMetadataReader.open(real)
        with self._state_lock:
            self._dataset_cache[key] = meta
            self._dataset_cache.move_to_end(key)
            while len(self._dataset_cache) > DATASET_CACHE_LIMIT:
                self._dataset_cache.popitem(last=False)
        return meta

    def _register_preview_file(self, image_path: str) -> str:
        with self._state_lock:
            self._preview_cache[image_path] = image_path
            self._preview_cache.move_to_end(image_path)
            while len(self._preview_cache) > PREVIEW_CACHE_LIMIT:
                _, evicted = self._preview_cache.popitem(last=False)
                for candidate in (evicted, evicted + ".map.json"):
                    try:
                        os.unlink(candidate)
                    except FileNotFoundError:
                        pass
        return image_path

    def _write_response(self, payload: Dict[str, Any]) -> None:
        line = json.dumps(payload, ensure_ascii=False, allow_nan=False) + "\n"
        with self._write_lock:
            self._out.write(line)
            self._out.flush()

    def _handle_ping(self, params: Dict[str, Any]) -> Dict[str, Any]:
        engine = self._get_engine()
        return {
            "version": SERVER_VERSION,
            "gmt_version": engine.get_version(),
            "gmt_bin": engine.gmt_bin,
            "gs_bin": shutil.which("gs", path=engine.child_path()),
            "python": sys.executable,
        }

    def _handle_open_dataset(self, params: Dict[str, Any]) -> Dict[str, Any]:
        path = params.get("path")
        if not path:
            raise ValueError("Missing required parameter: path")
        meta = self._get_dataset_meta(str(path))
        variables = []
        for var in meta.variables.values():
            default_cpt, default_sym = GMTEngine.default_style_for_variable(var.name)
            if var.is_categorical:
                default_cpt = "categorical"
                default_sym = False
            variables.append({
                "name": var.name,
                "display_title": var.display_title,
                "dimensions": list(var.dimensions),
                "shape": [int(s) for s in var.shape],
                "dtype": var.dtype,
                "attrs": [[str(k), str(_to_json_safe(v))] for k, v in var.attrs.items()],
                "is_2d_plotable": bool(var.is_2d_plotable),
                "x_dim": var.x_dim,
                "y_dim": var.y_dim,
                "slice_dims": list(var.slice_dims),
                "is_geographic": bool(var.is_geographic),
                "unsupported_reason": var.unsupported_reason,
                "x_range": _to_json_safe(list(var.x_range)) if var.x_range else None,
                "y_range": _to_json_safe(list(var.y_range)) if var.y_range else None,
                "v_range": _to_json_safe(list(var.v_range)) if var.v_range else None,
                "flag_values": _to_json_safe(list(var.flag_values)),
                "flag_meanings": list(var.flag_meanings),
                "is_categorical": bool(var.is_categorical),
                "default_cpt": default_cpt,
                "default_symmetric": default_sym,
            })

        return {
            "file_path": meta.file_path,
            "file_name": os.path.basename(meta.file_path),
            "dimensions": {str(k): int(v) for k, v in meta.dimensions.items()},
            "dimension_coords": {
                str(dim): [str(_to_json_safe(val)) for val in vals]
                for dim, vals in meta.dimension_coords.items()
            },
            "global_attrs": [[str(k), str(_to_json_safe(v))] for k, v in meta.global_attrs.items()],
            "variables": variables,
        }

    def _handle_recommend_projections(self, params: Dict[str, Any]) -> Dict[str, Any]:
        region = params.get("region")
        region_tuple = tuple(float(x) for x in region) if region is not None else None
        var_name = str(params.get("var_name") or "")
        var_attrs = params.get("var_attrs") or {}
        is_geographic = bool(params.get("is_geographic", True))
        if not is_geographic:
            projs = [("Cartesian linear", "X16c/10c", "Linear")]
        else:
            projs = GMTEngine.get_recommended_projections(region_tuple, var_name, var_attrs)
        return {
            "projections": [
                {"label": label, "code": code, "category": category}
                for label, code, category in projs
            ]
        }

    def _handle_get_cpt_options(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {"cpts": list(GMTEngine.CPT_OPTIONS)}

    def _resolve_config_from_params(self, cfg_dict: Dict[str, Any]) -> PlotConfig:
        source_path = str(cfg_dict.get("source_path") or "")
        meta = self._get_dataset_meta(source_path) if source_path and os.path.exists(source_path) else None
        return _plot_config_from_dict(cfg_dict, meta=meta)

    def _handle_render(self, params: Dict[str, Any]) -> Dict[str, Any]:
        engine = self._get_engine()
        cfg_dict = params.get("config")
        if not isinstance(cfg_dict, dict):
            raise ValueError("Missing required parameter: config")
        is_export = bool(params.get("is_export", False))
        include_hover = bool(params.get("include_hover", True)) and not is_export
        output_path = params.get("output_path")

        cfg = self._resolve_config_from_params(cfg_dict)
        if is_export:
            if not output_path:
                raise ValueError("Export requires output_path.")
            cfg.preview = False
            cfg.dpi = max(300, cfg.dpi)
            target_path = str(output_path)
        else:
            target_path = str(output_path) if output_path else os.path.join(
                self._temp_owner.name, f"preview_{uuid.uuid4().hex}.png"
            )

        t0 = time.perf_counter()
        resolved = engine.render(cfg, target_path)
        if not is_export and not output_path:
            self._register_preview_file(target_path)

        map_bbox = None
        dims_cm = None
        map_meta_path = Path(target_path + ".map.json")
        if map_meta_path.is_file():
            try:
                map_meta = json.loads(map_meta_path.read_text(encoding="utf-8"))
                map_bbox = [float(x) for x in map_meta.get("bbox", [])] or None
                dims_cm = [float(x) for x in map_meta.get("dims_cm", [])] or None
            except (OSError, ValueError):
                pass
        if dims_cm is None and resolved.region:
            dims_cm = list(engine.get_map_dimensions_cm(resolved.region, resolved.projection, resolved.gmt_conf))

        hover_b64 = None
        hover_size = 0
        if include_hover and resolved.region and dims_cm:
            uv = np.linspace(0.0, 1.0, HOVER_GRID_SIZE)
            u, v = np.meshgrid(uv, uv)
            points = np.column_stack((u.ravel(), v.ravel()))
            coords = engine.inverse_project_points(
                points,
                resolved.region,
                resolved.projection,
                tuple(dims_cm),
                resolved.gmt_conf,
            )
            arr = np.asarray(coords, dtype="<f4").reshape(HOVER_GRID_SIZE, HOVER_GRID_SIZE, 2)
            hover_b64 = base64.b64encode(arr.tobytes()).decode("ascii")
            hover_size = HOVER_GRID_SIZE
            del uv, u, v, points, coords, arr
            gc.collect()

        elapsed = time.perf_counter() - t0
        return {
            "image_path": target_path,
            "resolved_config": _plot_config_to_dict(resolved),
            "map_bbox": map_bbox,
            "dims_cm": dims_cm,
            "hover_grid_size": hover_size,
            "hover_b64": hover_b64,
            "elapsed_sec": float(elapsed),
        }

    def _handle_scan_range(self, params: Dict[str, Any]) -> Dict[str, Any]:
        engine = self._get_engine()
        grid_spec = str(params.get("grid_spec") or "")
        if not grid_spec:
            source_path = str(params.get("source_path") or "")
            variable_name = str(params.get("variable_name") or "")
            slice_indices = {str(k): int(v) for k, v in (params.get("slice_indices") or {}).items()}
            if not source_path or not variable_name:
                raise ValueError("scan_range requires grid_spec or source_path + variable_name.")
            meta = self._get_dataset_meta(source_path)
            if variable_name not in meta.variables:
                raise ValueError(f"Variable '{variable_name}' not found in dataset.")
            grid_spec = NetCDFMetadataReader.build_gmt_grid_spec(
                meta.file_path, meta.variables[variable_name], slice_indices
            )

        region = params.get("region")
        region_tuple = tuple(float(x) for x in region) if region is not None else None
        mask_mode = str(params.get("mask_mode") or "none")
        symmetric = bool(params.get("symmetric", False))

        info = engine.get_masked_grid_info(grid_spec, region_tuple, mask_mode)
        lo, hi = float(info["z_min"]), float(info["z_max"])
        if symmetric:
            max_abs = max(abs(lo), abs(hi))
            lo, hi = -max_abs, max_abs
        return {"z_min": lo, "z_max": hi}

    def _handle_selection_region(self, params: Dict[str, Any]) -> Dict[str, Any]:
        engine = self._get_engine()
        region = params.get("region")
        dims_cm = params.get("dims_cm")
        if not region or not dims_cm:
            return {"region": None}
        selected = engine.compute_selection_region(
            float(params["u0"]),
            float(params["v0"]),
            float(params["u1"]),
            float(params["v1"]),
            tuple(float(x) for x in region),
            str(params["projection"]),
            tuple(float(x) for x in dims_cm),
            str(params.get("gmt_conf") or ""),
        )
        return {"region": list(selected) if selected is not None else None}

    def _handle_generate_script(self, params: Dict[str, Any]) -> Dict[str, Any]:
        engine = self._get_engine()
        cfg_dict = params.get("config")
        if not isinstance(cfg_dict, dict):
            raise ValueError("Missing required parameter: config")
        cfg = self._resolve_config_from_params(cfg_dict)
        output_filename = str(params.get("output_filename") or "output.png")
        script = engine.generate_script(cfg, output_filename=output_filename)
        return {"script": script}

    def _handle_parse_script(self, params: Dict[str, Any]) -> Dict[str, Any]:
        script = str(params.get("script") or "")
        fallback_dict = params.get("fallback_config")
        if not isinstance(fallback_dict, dict):
            raise ValueError("Missing required parameter: fallback_config")
        fallback = self._resolve_config_from_params(fallback_dict)
        parsed = GMTEngine.parse_script_to_config(script, fallback)
        return {"config": _plot_config_to_dict(parsed)}

    def _handle_run_script(self, params: Dict[str, Any]) -> Dict[str, Any]:
        engine = self._get_engine()
        script = str(params.get("script") or "")
        if not script.strip():
            raise ValueError("Script cannot be empty.")
        fallback_dict = params.get("fallback_config")
        fallback = self._resolve_config_from_params(fallback_dict) if isinstance(fallback_dict, dict) else None

        with tempfile.TemporaryDirectory(prefix="graticule_script_", dir=self._temp_owner.name) as td:
            script_path = os.path.join(td, "run_plot.sh")
            with open(script_path, "w", encoding="utf-8") as stream:
                stream.write(script)
            env = os.environ.copy()
            env["PATH"] = engine.child_path(env.get("PATH", ""))
            res = subprocess.run(
                ["bash", script_path],
                cwd=td,
                env=env,
                capture_output=True,
                text=True,
                timeout=180,
            )
            if res.returncode:
                detail = (res.stderr or res.stdout)[-12000:]
                raise RuntimeError(detail or f"Script exited with status {res.returncode}")

            files = [
                os.path.join(td, fname)
                for fname in os.listdir(td)
                if fname.lower().endswith((".png", ".jpg", ".jpeg", ".tif", ".tiff"))
            ]
            image_path = None
            if files:
                newest = max(files, key=os.path.getmtime)
                ext = os.path.splitext(newest)[1] or ".png"
                dst = os.path.join(self._temp_owner.name, f"custom_{uuid.uuid4().hex}{ext}")
                shutil.copyfile(newest, dst)
                self._register_preview_file(dst)
                image_path = dst

            parsed_config = None
            if fallback is not None:
                try:
                    parsed = GMTEngine.parse_script_to_config(script, fallback)
                    parsed_config = _plot_config_to_dict(parsed)
                except ValueError:
                    parsed_config = None

            return {
                "image_path": image_path,
                "parsed_config": parsed_config,
                "stdout": res.stdout[-8000:],
                "stderr": res.stderr[-8000:],
            }

    def _handle_cn_border_status(self, params: Dict[str, Any]) -> Dict[str, Any]:
        explicit_dir = str(params.get("cn_border_dir") or "")
        return GMTEngine.cn_border_status(explicit_dir)

    def _handle_install_cn_border(self, params: Dict[str, Any]) -> Dict[str, Any]:
        dest_dir = params.get("dest_dir")
        dest_str = str(dest_dir) if dest_dir else None
        zip_path = params.get("zip_path")
        if zip_path:
            return GMTEngine.install_cn_border_from_zip(str(zip_path), dest_str)
        return GMTEngine.download_cn_border_dataset(dest_str)

    def dispatch(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        handlers = {
            "ping": self._handle_ping,
            "open_dataset": self._handle_open_dataset,
            "recommend_projections": self._handle_recommend_projections,
            "get_cpt_options": self._handle_get_cpt_options,
            "render": self._handle_render,
            "scan_range": self._handle_scan_range,
            "selection_region": self._handle_selection_region,
            "generate_script": self._handle_generate_script,
            "parse_script": self._handle_parse_script,
            "run_script": self._handle_run_script,
            "cn_border_status": self._handle_cn_border_status,
            "install_cn_border": self._handle_install_cn_border,
        }
        handler = handlers.get(method)
        if handler is None:
            raise ValueError(f"Unknown RPC method: {method}")
        return handler(params)

    def _run_and_reply(self, req_id: Any, method: str, params: Dict[str, Any]) -> None:
        try:
            result = self.dispatch(method, params)
            self._write_response({"id": req_id, "ok": True, "result": result})
        except Exception as exc:
            self._write_response({
                "id": req_id,
                "ok": False,
                "error": str(exc) or traceback.format_exc(limit=3),
            })

    def serve(self, in_stream=None) -> int:
        stream = in_stream or sys.stdin
        try:
            for raw_line in stream:
                if self._stop_event.is_set():
                    break
                line = raw_line.strip()
                if not line:
                    continue
                req_id = None
                try:
                    req = json.loads(line)
                    req_id = req.get("id")
                    method = str(req.get("method") or "")
                    params = req.get("params") or {}
                    if not isinstance(params, dict):
                        raise ValueError("RPC params must be a JSON object.")
                except Exception as exc:
                    self._write_response({"id": req_id, "ok": False, "error": f"Invalid request: {exc}"})
                    continue

                if method == "shutdown":
                    self._stop_event.set()
                    self._write_response({"id": req_id, "ok": True, "result": {"status": "shutting_down"}})
                    break

                if method in self.HEAVY_METHODS:
                    pool = self._heavy_pool
                elif method in self.FAST_METHODS:
                    pool = self._fast_pool
                else:
                    self._write_response({"id": req_id, "ok": False, "error": f"Unknown RPC method: {method}"})
                    continue

                fut = pool.submit(self._run_and_reply, req_id, method, params)
                with self._state_lock:
                    self._pending_futures.add(fut)
                fut.add_done_callback(lambda f: self._discard_future(f))
        finally:
            self.close()
        return 0

    def _discard_future(self, fut) -> None:
        with self._state_lock:
            self._pending_futures.discard(fut)

    def close(self, fast: bool = False) -> None:
        self._stop_event.set()
        wait_pool = not fast and not self._stop_event.is_set()
        self._fast_pool.shutdown(wait=wait_pool, cancel_futures=True)
        self._heavy_pool.shutdown(wait=wait_pool, cancel_futures=True)
        with self._state_lock:
            if self._engine is not None:
                self._engine.close()
                self._engine = None
            self._preview_cache.clear()
            self._dataset_cache.clear()
        self._temp_owner.cleanup()


def main() -> int:
    server = RPCServer()

    def _fast_sigterm_exit(_signum, _frame):
        try:
            shutil.rmtree(server._temp_owner.name, ignore_errors=True)
        except Exception:
            pass
        os._exit(0)

    try:
        signal.signal(signal.SIGTERM, _fast_sigterm_exit)
    except Exception:
        pass
    return server.serve()


if __name__ == "__main__":
    sys.exit(main())
