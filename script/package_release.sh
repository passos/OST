#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/OST.xcodeproj"
DERIVED_DATA="$ROOT_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/OST.app"
OUTPUT_DIR="$ROOT_DIR/.build/release"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$ROOT_DIR/script/verify_privacy.sh" --static

mkdir -p "$ROOT_DIR/.cache/swiftpm" "$ROOT_DIR/.cache/clang" "$OUTPUT_DIR"

SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/swiftpm" \
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang" \
swift package \
  --package-path "$ROOT_DIR" \
  --scratch-path "$ROOT_DIR/.build" \
  --disable-sandbox \
  resolve

xcodebuild \
  -project "$PROJECT" \
  -scheme OST \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$ROOT_DIR/.build" \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Built app bundle was not found: $APP_BUNDLE" >&2
  exit 1
fi

"$ROOT_DIR/script/sign_adhoc.sh" "$APP_BUNDLE"
OST_APP_BUNDLE="$APP_BUNDLE" "$ROOT_DIR/script/verify_privacy.sh"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")"
if [[ -n "${OST_RELEASE_TAG:-}" && "v$VERSION" != "$OST_RELEASE_TAG" ]]; then
  echo "Release tag $OST_RELEASE_TAG does not match app version v$VERSION." >&2
  exit 1
fi

ARCHIVE="$OUTPUT_DIR/OST-$VERSION-macos-arm64.zip"
rm -f "$ARCHIVE"
(
  cd "$(dirname "$APP_BUNDLE")"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$ARCHIVE" "$(basename "$APP_BUNDLE")"
)

unzip -t "$ARCHIVE"
ARCHIVE_LISTING="$(unzip -Z1 "$ARCHIVE")"
grep -Fxq 'OST.app/Contents/MacOS/OST' <<< "$ARCHIVE_LISTING"
if grep -Eq '(^__MACOSX/|(^|/)\._|(^|/)\.DS_Store$)' <<< "$ARCHIVE_LISTING"; then
  echo "Release archive contains macOS metadata files." >&2
  exit 1
fi

shasum -a 256 "$ARCHIVE"
echo "Created release artifact: $ARCHIVE"
