#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${GRATICULE_PYTHON:-}" ]]; then
    PYTHON_BIN="$GRATICULE_PYTHON"
elif [[ -n "${GMT_PANOPLY_PYTHON:-}" ]]; then
    PYTHON_BIN="$GMT_PANOPLY_PYTHON"
elif [[ -x "$DIR/.venv/bin/python" ]]; then
    PYTHON_BIN="$DIR/.venv/bin/python"
elif [[ -n "${CONDA_PREFIX:-}" && -x "$CONDA_PREFIX/bin/python" ]]; then
    PYTHON_BIN="$CONDA_PREFIX/bin/python"
elif [[ -x "$HOME/micromamba/envs/dev/bin/python" ]]; then
    PYTHON_BIN="$HOME/micromamba/envs/dev/bin/python"
elif [[ -x "$HOME/miniconda3/envs/dev/bin/python" ]]; then
    PYTHON_BIN="$HOME/miniconda3/envs/dev/bin/python"
else
    PYTHON_BIN="$(command -v python3)"
fi
export PYTHONPATH="$DIR${PYTHONPATH:+:$PYTHONPATH}"
exec "$PYTHON_BIN" -B -m graticule.cli "$@"
