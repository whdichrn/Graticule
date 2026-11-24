#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_DIR/.." && pwd)"
DIST_DIR="$MACOS_DIR/dist"
APP_BUNDLE="$DIST_DIR/Graticule.app"

INSTALL_APP=false
SET_DEFAULT=false
PORTABLE=false
UNIVERSAL=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_APP=true ;;
        --set-default) SET_DEFAULT=true ;;
        --portable) PORTABLE=true ;;
        --universal) UNIVERSAL=true ;;
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
BIN_PATH=""
if [[ "$UNIVERSAL" == true ]]; then
    if swift build -c release --arch arm64 --arch x86_64 --package-path "$MACOS_DIR"; then
        BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$MACOS_DIR" --show-bin-path)"
        BIN_PATH="$BIN_DIR/Graticule"
    else
        echo "Notice: Universal (arm64 + x86_64) build unavailable on this toolchain; falling back to arm64." >&2
    fi
fi

if [[ -z "$BIN_PATH" || ! -x "$BIN_PATH" ]]; then
    swift build -c release --package-path "$MACOS_DIR"
    BIN_DIR="$(swift build -c release --package-path "$MACOS_DIR" --show-bin-path)"
    BIN_PATH="$BIN_DIR/Graticule"
fi

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Release binary missing: $BIN_PATH" >&2
    exit 1
fi

echo "== Packaging $APP_BUNDLE"
SDK_VERSION="$(xcrun --show-sdk-version)"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/backend/graticule"

stamp_binary() {
    local target="$1"
    local arches
    arches="$(lipo -archs "$target" 2>/dev/null || true)"
    if [[ "$arches" == *" "* ]]; then
        local tmpdir
        tmpdir="$(mktemp -d)"
        local slices=()
        for arch in $arches; do
            local slice="$tmpdir/Graticule.$arch"
            lipo "$target" -thin "$arch" -output "$slice"
            xcrun vtool -set-build-version macos 13.0 "$SDK_VERSION" -replace -output "$slice" "$slice"
            slices+=("$slice")
        done
        lipo -create "${slices[@]}" -output "$target"
        rm -rf "$tmpdir"
    else
        xcrun vtool -set-build-version macos 13.0 "$SDK_VERSION" -replace -output "$target" "$target"
    fi
}

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/Graticule"
stamp_binary "$APP_BUNDLE/Contents/MacOS/Graticule"

# Bundle Python backend inside the .app so portable releases run without cloning the repo
rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' \
    "$REPO_ROOT/graticule/" "$APP_BUNDLE/Contents/Resources/backend/graticule/"

ICON_BUNDLE="$MACOS_DIR/Resources/Graticule.icon"
ICTOOL_BIN="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

if [[ -d "$ICON_BUNDLE" ]] && xcrun --find actool >/dev/null 2>&1; then
    TMP_PLIST="$(mktemp)"
    xcrun actool "$ICON_BUNDLE" \
        --compile "$APP_BUNDLE/Contents/Resources" \
        --app-icon Graticule \
        --include-all-app-icons \
        --platform macosx \
        --minimum-deployment-target 13.0 \
        --output-partial-info-plist "$TMP_PLIST" >/dev/null
    rm -f "$TMP_PLIST"
fi

if [[ -f "$APP_BUNDLE/Contents/Resources/Graticule.icns" ]]; then
    cp "$APP_BUNDLE/Contents/Resources/Graticule.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
elif [[ -d "$ICON_BUNDLE" && -x "$ICTOOL_BIN" ]]; then
    TMP_ICON_WORK="$(mktemp -d)"
    "$ICTOOL_BIN" "$ICON_BUNDLE" --export-image --output-file "$TMP_ICON_WORK/base.png" \
        --platform macOS --rendition Default --width 512 --height 512 --scale 2 --design-generation 27 >/dev/null
    ICONSET_DIR="$TMP_ICON_WORK/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    sips -z 16 16     "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32     "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64     "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256   "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512   "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$TMP_ICON_WORK/base.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    cp "$TMP_ICON_WORK/base.png" "$ICONSET_DIR/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$TMP_ICON_WORK"
else
    TMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
    swift "$SCRIPT_DIR/make_icon.swift" "$TMP_ICONSET"
    iconutil -c icns "$TMP_ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$TMP_ICONSET")"
fi

if [[ -f "$MACOS_DIR/Resources/Credits.rtf" ]]; then
    cp "$MACOS_DIR/Resources/Credits.rtf" "$APP_BUNDLE/Contents/Resources/Credits.rtf"
fi

INFO_ROOT="$REPO_ROOT"
INFO_PY="$PYTHON_BIN"
INFO_GMT="$GMT_BIN_PATH"
if [[ "$PORTABLE" == true ]]; then
    INFO_ROOT=""
    INFO_PY=""
    INFO_GMT=""
fi

"$PYTHON_BIN" -B - "$MACOS_DIR/Resources/Info.plist.template" "$APP_BUNDLE/Contents/Info.plist" "$INFO_ROOT" "$INFO_PY" "$INFO_GMT" "$SDK_VERSION" <<'PY'
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
