import base64
import json
import os
from pathlib import Path
import subprocess
import sys

import numpy as np


class _RPCProcess:
    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, "-B", "-m", "graticule.backend.rpc_server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._seq = 0

    def call(self, method, params=None):
        self._seq += 1
        req = {"id": self._seq, "method": method, "params": params or {}}
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        assert line, f"RPC server exited unexpectedly. stderr:\n{self.proc.stderr.read()}"
        resp = json.loads(line)
        assert resp["id"] == self._seq
        return resp

    def close(self):
        try:
            resp = self.call("shutdown")
            assert resp["ok"] is True
        finally:
            self.proc.stdin.close()
            rc = self.proc.wait(timeout=15)
            assert rc == 0, self.proc.stderr.read()


def test_rpc_server_end_to_end(engine, grids, tmp_path):
    global_nc, regional_nc = grids
    rpc = _RPCProcess()
    try:
        ping = rpc.call("ping")
        assert ping["ok"] is True
        assert ping["result"]["version"] == "0.7.2"
        assert ping["result"]["gmt_version"]

        ds = rpc.call("open_dataset", {"path": str(regional_nc)})
        assert ds["ok"] is True
        meta = ds["result"]
        assert meta["file_name"] == "regional.nc"
        temp_var = next(v for v in meta["variables"] if v["name"] == "temp")
        assert temp_var["is_2d_plotable"] is True
        assert temp_var["slice_dims"] == ["time", "depth"]

        projs = rpc.call("recommend_projections", {
            "region": [100.0, 130.0, 20.0, 40.0],
            "var_name": "temp",
            "var_attrs": {},
            "is_geographic": True,
        })
        assert projs["ok"] is True
        assert len(projs["result"]["projections"]) >= 1

        scan = rpc.call("scan_range", {
            "source_path": str(regional_nc),
            "variable_name": "temp",
            "slice_indices": {"time": 1, "depth": 2},
            "region": [100.0, 130.0, 20.0, 40.0],
            "mask_mode": "none",
            "symmetric": False,
        })
        assert scan["ok"] is True
        assert scan["result"]["z_min"] < scan["result"]["z_max"]

        cfg = {
            "grid_spec": "",
            "source_path": str(global_nc),
            "variable_name": "field",
            "region": [0.0, 360.0, -90.0, 90.0],
            "projection": "W180/16c",
            "projection_mode": "manual",
            "cpt": "turbo",
            "show_coast": False,
            "dpi": 90,
            "preview": True,
        }
        rendered = rpc.call("render", {"config": cfg, "include_hover": True})
        assert rendered["ok"] is True, rendered.get("error")
        res = rendered["result"]
        assert Path(res["image_path"]).is_file()
        assert len(res["map_bbox"]) == 4
        assert len(res["dims_cm"]) == 2
        n = res["hover_grid_size"]
        assert n == 65
        raw = base64.b64decode(res["hover_b64"])
        hover = np.frombuffer(raw, dtype="<f4").reshape(n, n, 2)
        center = hover[n // 2, n // 2]
        assert np.isfinite(center).all()
        assert abs(center[0] - 180.0) < 2.0 and abs(center[1]) < 2.0

        sel = rpc.call("selection_region", {
            "u0": 0.4,
            "v0": 0.4,
            "u1": 0.6,
            "v1": 0.6,
            "region": res["resolved_config"]["region"],
            "projection": res["resolved_config"]["projection"],
            "dims_cm": res["dims_cm"],
            "gmt_conf": "",
        })
        assert sel["ok"] is True
        box = sel["result"]["region"]
        assert box is not None and box[0] < 180.0 < box[1] and box[2] < 0.0 < box[3]

        script_res = rpc.call("generate_script", {"config": res["resolved_config"], "output_filename": "out.png"})
        assert script_res["ok"] is True
        script = script_res["result"]["script"]
        assert "gmt begin" in script

        parsed = rpc.call("parse_script", {"script": script, "fallback_config": res["resolved_config"]})
        assert parsed["ok"] is True
        assert parsed["result"]["config"]["projection"] == "W180/16c"

        run_res = rpc.call("run_script", {"script": script, "fallback_config": res["resolved_config"]})
        assert run_res["ok"] is True, run_res.get("error")
        assert Path(run_res["result"]["image_path"]).is_file()

        # Verify CN-border status query works cleanly.
        cn_status = rpc.call("cn_border_status", {"cn_border_dir": str(tmp_path)})
        assert cn_status["ok"] is True
        assert "installed" in cn_status["result"] and "default_dir" in cn_status["result"]

        # Verify structured errors on bad request without crashing the server.
        bad = rpc.call("open_dataset", {"path": str(tmp_path / "missing.nc")})
        assert bad["ok"] is False and "not found" in bad["error"].lower()

        bad_method = rpc.call("nonexistent_method")
        assert bad_method["ok"] is False

        # Server still responds cleanly after errors.
        ping2 = rpc.call("ping")
        assert ping2["ok"] is True
    finally:
        rpc.close()


def test_rpc_server_fast_sigterm_exit(tmp_path):
    import glob
    import tempfile
    import time

    before = set(glob.glob(os.path.join(tempfile.gettempdir(), "graticule_rpc_*")))
    proc = subprocess.Popen(
        [sys.executable, "-B", "-m", "graticule.backend.rpc_server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        proc.stdin.write(json.dumps({"id": 1, "method": "ping", "params": {}}) + "\n")
        proc.stdin.flush()
        resp = json.loads(proc.stdout.readline())
        assert resp["ok"] is True
        created = set(glob.glob(os.path.join(tempfile.gettempdir(), "graticule_rpc_*"))) - before

        t0 = time.monotonic()
        proc.terminate()
        rc = proc.wait(timeout=3)
        elapsed = time.monotonic() - t0
        assert rc == 0
        assert elapsed < 0.8
        for d in created:
            assert not os.path.exists(d)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=2)
