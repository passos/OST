#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OST"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/OST.xcodeproj"
DERIVED_DATA="$ROOT_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/OST.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/OST"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$ROOT_DIR/script/verify_privacy.sh" --static

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme OST
  -configuration Debug
  -derivedDataPath "$DERIVED_DATA"
  -clonedSourcePackagesDirPath "$ROOT_DIR/.build"
  -disableAutomaticPackageResolution
  -skipPackageUpdates
  -skipPackagePluginValidation
  -skipMacroValidation
  -destination 'platform=macOS,arch=arm64'
)

if [[ -n "${OST_DEVELOPMENT_TEAM:-}" ]]; then
  BUILD_ARGS+=("DEVELOPMENT_TEAM=$OST_DEVELOPMENT_TEAM")
else
  BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${BUILD_ARGS[@]}" build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Built app bundle was not found: $APP_BUNDLE" >&2
  exit 1
fi

if [[ -z "${OST_DEVELOPMENT_TEAM:-}" ]]; then
  "$ROOT_DIR/script/sign_adhoc.sh" "$APP_BUNDLE"
  echo "Using a local ad-hoc signature. Set OST_DEVELOPMENT_TEAM for development or distribution signing." >&2
fi

"$ROOT_DIR/script/verify_privacy.sh"

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
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "OST"'
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.reserve.OST"'
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
