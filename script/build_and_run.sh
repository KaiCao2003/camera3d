#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BrainBuilder"
BUNDLE_ID="dev.camera3d.BrainBuilder"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_RESOURCES="$APP_CONTENTS/Resources"
WORKER_RESOURCES="$APP_RESOURCES/registration-worker"
BUILD_CONFIGURATION="release"

if [[ -x /opt/homebrew/bin/uv ]]; then
  UV_BIN=/opt/homebrew/bin/uv
elif [[ -x /usr/local/bin/uv ]]; then
  UV_BIN=/usr/local/bin/uv
else
  echo "BrainBuilder requires uv to provision the Python 3.11 registration worker." >&2
  exit 1
fi

cd "$ROOT_DIR"
"$UV_BIN" sync --frozen --project "$ROOT_DIR/registration-worker" --python 3.11
swift build -c "$BUILD_CONFIGURATION"
BUILD_BINARY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$WORKER_RESOURCES" "$APP_RESOURCES/tools"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/registration-worker/brainbuilder_worker.py" "$WORKER_RESOURCES/"
cp "$ROOT_DIR/registration-worker/abba_bridge.py" "$WORKER_RESOURCES/"
cp "$ROOT_DIR/registration-worker/abba_review.py" "$WORKER_RESOURCES/"
mkdir -p "$WORKER_RESOURCES/abba"
cp "$ROOT_DIR/registration-worker/abba/pyproject.toml" "$WORKER_RESOURCES/abba/"
cp "$ROOT_DIR/registration-worker/abba/run-local.command" "$WORKER_RESOURCES/abba/"
cp "$ROOT_DIR/registration-worker/pyproject.toml" "$WORKER_RESOURCES/"
cp "$ROOT_DIR/registration-worker/uv.lock" "$WORKER_RESOURCES/"
cp "$ROOT_DIR/registration-worker/README.md" "$WORKER_RESOURCES/"
cp "$UV_BIN" "$APP_RESOURCES/tools/uv"
chmod +x "$APP_RESOURCES/tools/uv"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.education</string>
  <key>LSUIElement</key>
  <false/>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign nested executable code before sealing the application bundle. This is an
# ad-hoc development signature; distribution still requires a Developer ID and
# notarization.
/usr/bin/codesign --force --sign - --timestamp=none "$APP_RESOURCES/tools/uv"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --direct|direct)
    "$APP_BINARY" &
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brainbuilder-package-verify.XXXXXX")"
    trap 'rm -rf "$VERIFY_DIR"' EXIT
    (
      cd "$VERIFY_DIR"
      env -u BRAINBUILDER_WORKER_ROOT "$APP_BINARY" --registration-doctor "$VERIFY_DIR/doctor"
    )
    ;;
  --headless-scan|headless-scan)
    "$APP_BINARY" --headless-scan "${2:-data}"
    ;;
  --export-obj|export-obj)
    "$APP_BINARY" --export-obj "${2:-data}" "${3:-exports/last-reconstruction}"
    ;;
  --download-atlas|download-atlas)
    "$APP_BINARY" --download-atlas "${2:-exports/allen-ccf-2020}"
    ;;
  --registration-prepare|registration-prepare)
    "$APP_BINARY" --registration-prepare "${2:-data}" "${3:-exports/registration-worker}"
    ;;
  --registration-estimate-pose|registration-estimate-pose)
    "$APP_BINARY" --registration-estimate-pose "${2:-exports/registration-worker/project.json}" "${3:-exports/registration-worker}"
    ;;
  --registration-register-slice|registration-register-slice)
    "$APP_BINARY" --registration-register-slice "${2:?project.json required}" "${3:?slice-id required}" "${4:-affine}" "${5:-exports/registration-worker}"
    ;;
  --registration-export-atlas|registration-export-atlas)
    "$APP_BINARY" --registration-export-atlas "${2:-exports/registration-worker/project.json}" "${3:-exports/atlas-registration}"
    ;;
  --registration-doctor|registration-doctor)
    "$APP_BINARY" --registration-doctor "${2:-exports/registration-worker-doctor}"
    ;;
  *)
    echo "usage: $0 [run|--direct|--debug|--logs|--telemetry|--verify|--headless-scan [data-dir]|--export-obj [data-dir] [output-dir]|--download-atlas [output-dir]|--registration-prepare [data-dir] [output-dir]|--registration-estimate-pose [project.json] [output-dir]|--registration-register-slice <project.json> <slice-id> [affine|spline] [output-dir]|--registration-export-atlas [project.json] [output-dir]|--registration-doctor [output-dir]]" >&2
    exit 2
    ;;
esac
