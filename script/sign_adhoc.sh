#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT_DIR/DerivedData/Build/Products/Debug/OST.app}"
XPC="$APP/Contents/XPCServices/OSTModelDownloaderXPC.xpc"

if [[ ! -d "$APP" || ! -d "$XPC" ]]; then
  echo "Build OST.app with the embedded XPC service before signing." >&2
  exit 1
fi

# Seal nested code first, then restore the distinct XPC and app entitlements.
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --force --sign - --timestamp=none \
  --entitlements "$ROOT_DIR/Xcode/ModelDownloaderXPC/ModelDownloaderXPC.entitlements" \
  "$XPC"
codesign --force --sign - --timestamp=none \
  --entitlements "$ROOT_DIR/Xcode/OSTApp/OSTApp.entitlements" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Applied a complete local ad-hoc signature to OST.app and its XPC service."
