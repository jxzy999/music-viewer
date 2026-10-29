#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="Music Viewer"
EXECUTABLE_NAME="ScoreFilm"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
LEGACY_APP_BUNDLE="$ROOT_DIR/dist/ScoreFilm.app"
running_app_pids() {
    local candidates app_pid executable_path
    candidates="$(pgrep -x "$EXECUTABLE_NAME" || true)"
    while IFS= read -r app_pid; do
        [[ -n "$app_pid" ]] || continue
        executable_path="$(ps -p "$app_pid" -o comm= || true)"
        if [[ "$executable_path" == "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" || "$executable_path" == "$LEGACY_APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" ]]; then
            printf '%s\n' "$app_pid"
        fi
    done <<< "$candidates"
}
ACTIVE_APP_PIDS="$(running_app_pids)"
while IFS= read -r app_pid; do
    if [[ -n "$app_pid" ]]; then kill -TERM "$app_pid" 2>/dev/null || true; fi
done <<< "$ACTIVE_APP_PIDS"
for ((attempt=0; attempt<300; attempt++)); do
    if [[ -z "$(running_app_pids)" ]]; then break; fi
    sleep 0.1
done
if [[ -n "$(running_app_pids)" ]]; then
    printf '%s\n' 'Music Viewer 尚未安全退出。请先在应用中保存并退出，再重新运行；本次未覆盖运行中的应用。' >&2
    exit 1
fi
swift build
BUILD_DIR="$(swift build --show-bin-path)"
if [[ ! -e "$APP_BUNDLE" && -d "$LEGACY_APP_BUNDLE" ]]; then
    mv "$LEGACY_APP_BUNDLE" "$APP_BUNDLE"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
for bundle in "$BUILD_DIR"/ScoreFilm_*.bundle; do
    if [ -d "$bundle" ]; then /usr/bin/ditto "$bundle" "$APP_BUNDLE/Contents/Resources/$(basename "$bundle")"; fi
done
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScoreFilm</string>
<key>CFBundleIdentifier</key><string>local.scorefilm.mac</string>
<key>CFBundleName</key><string>Music Viewer</string>
<key>CFBundleDisplayName</key><string>Music Viewer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Music Viewer Project</string><key>CFBundleTypeRole</key><string>Editor</string><key>LSItemContentTypes</key><array><string>local.scorefilm.project</string></array></dict><dict><key>CFBundleTypeName</key><string>MusicXML Score</string><key>CFBundleTypeRole</key><string>Viewer</string><key>CFBundleTypeExtensions</key><array><string>musicxml</string><string>mxl</string><string>xml</string></array></dict></array>
<key>UTExportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>local.scorefilm.project</string><key>UTTypeDescription</key><string>Music Viewer Project</string><key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>scorefilm</string></array></dict></dict></array>
</dict></plist>
PLIST
open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  run) open_app ;;
  --build-only) /usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" ;;
  --verify) open_app; sleep 2; [[ -n "$(running_app_pids)" ]] ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate 'process == "ScoreFilm"' ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.scorefilm.mac"' ;;
  *) echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
