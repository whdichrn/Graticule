#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_DIR/.." && pwd)"
DIST_DIR="$MACOS_DIR/dist"
APP_BUNDLE="$DIST_DIR/Graticule.app"

INSTALL_APP=false
SET_DEFAULT=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_APP=true ;;
        --set-default) SET_DEFAULT=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

detect_python() {
    if [[ -n "${GRATICULE_PYTHON:-}" && -x "${GRATICULE_PYTHON}" ]]; then
        echo "$GRATICULE_PYTHON"
    elif [[ -n "${GMT_PANOPLY_PYTHON:-}" && -x "${GMT_PANOPLY_PYTHON}" ]]; then
        echo "$GMT_PANOPLY_PYTHON"
    elif [[ -x "$HOME/micromamba/envs/dev/bin/python" ]]; then
        echo "$HOME/micromamba/envs/dev/bin/python"
    elif [[ -x "$REPO_ROOT/.venv/bin/python" ]]; then
        echo "$REPO_ROOT/.venv/bin/python"
    else
        command -v python3 || true
    fi
}

PYTHON_BIN="$(detect_python)"
GMT_BIN_PATH="${GMT_BIN:-}"
if [[ -z "$GMT_BIN_PATH" && -n "$PYTHON_BIN" && -x "$(dirname "$PYTHON_BIN")/gmt" ]]; then
    GMT_BIN_PATH="$(dirname "$PYTHON_BIN")/gmt"
elif [[ -z "$GMT_BIN_PATH" ]]; then
    GMT_BIN_PATH="$(command -v gmt || true)"
fi

echo "== Building Graticule (release)"
swift build -c release --package-path "$MACOS_DIR"
BIN_DIR="$(swift build -c release --package-path "$MACOS_DIR" --show-bin-path)"
BIN_PATH="$BIN_DIR/Graticule"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Release binary missing: $BIN_PATH" >&2
    exit 1
fi

echo "== Packaging $APP_BUNDLE"
SDK_VERSION="$(xcrun --show-sdk-version)"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/Graticule"
xcrun vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
    -output "$APP_BUNDLE/Contents/MacOS/Graticule" "$APP_BUNDLE/Contents/MacOS/Graticule"

TMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$SCRIPT_DIR/make_icon.swift" "$TMP_ICONSET"
iconutil -c icns "$TMP_ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$TMP_ICONSET")"

if [[ -f "$MACOS_DIR/Resources/Credits.rtf" ]]; then
    cp "$MACOS_DIR/Resources/Credits.rtf" "$APP_BUNDLE/Contents/Resources/Credits.rtf"
fi

"$PYTHON_BIN" -B - "$MACOS_DIR/Resources/Info.plist.template" "$APP_BUNDLE/Contents/Info.plist" "$REPO_ROOT" "$PYTHON_BIN" "$GMT_BIN_PATH" "$SDK_VERSION" <<'PY'
import sys
from pathlib import Path

template_path, out_path, root, py_bin, gmt_bin, sdk_ver = sys.argv[1:7]
text = Path(template_path).read_text(encoding="utf-8")
text = (
    text.replace("__SOURCE_ROOT__", root)
    .replace("__DEFAULT_PYTHON__", py_bin)
    .replace("__DEFAULT_GMT__", gmt_bin)
    .replace("__SDK_VERSION__", sdk_ver)
)
Path(out_path).write_text(text, encoding="utf-8")
PY

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"
echo "Built: $APP_BUNDLE"

if [[ "$INSTALL_APP" == true ]]; then
    TARGET_APP="/Applications/Graticule.app"
    rm -rf "$TARGET_APP"
    cp -R "$APP_BUNDLE" "$TARGET_APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP"
    echo "Installed: $TARGET_APP"
    if [[ "$SET_DEFAULT" == true ]]; then
        "$TARGET_APP/Contents/MacOS/Graticule" --register-default --app-path "$TARGET_APP"
    fi
elif [[ "$SET_DEFAULT" == true ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"
    "$APP_BUNDLE/Contents/MacOS/Graticule" --register-default --app-path "$APP_BUNDLE"
fi
