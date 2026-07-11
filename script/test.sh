#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$ROOT_DIR/script/verify_privacy.sh" --static

ARGS=(
  -project "$ROOT_DIR/OST.xcodeproj"
  -scheme OST
  -configuration Debug
  -derivedDataPath "$ROOT_DIR/DerivedDataTests"
  -clonedSourcePackagesDirPath "$ROOT_DIR/.build"
  -disableAutomaticPackageResolution
  -skipPackageUpdates
  -skipPackagePluginValidation
  -skipMacroValidation
  -destination 'platform=macOS,arch=arm64'
)

if [[ -n "${OST_DEVELOPMENT_TEAM:-}" ]]; then
  ARGS+=("DEVELOPMENT_TEAM=$OST_DEVELOPMENT_TEAM")
else
  echo "OST_DEVELOPMENT_TEAM is not set; running unit tests without signing and skipping UI launch tests." >&2
  ARGS+=(CODE_SIGNING_ALLOWED=NO -skip-testing:OSTUITests)
fi

xcodebuild "${ARGS[@]}" test
