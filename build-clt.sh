#!/bin/zsh
# Build Float with only the Command Line Tools (no Xcode, no XcodeGen).
# The CLT toolchain lacks the SwiftUI macro plugin, so @State is rewritten to the FState
# property wrapper (Support/FState.swift) in a temp copy; the checked-in sources stay upstream-style.
# Usage: ./build-clt.sh [--install]   (install replaces ~/Applications/Float.app)
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/src"
cp -R Float/Sources/ "$BUILD/src/"
cp Support/FState.swift "$BUILD/src/"
find "$BUILD/src" -name '*.swift' ! -name FState.swift -exec sed -i '' -E 's/@State([^A-Za-z0-9_]|$)/@FState\1/g' {} +
swiftc -O -swift-version 5 -module-name FloatApp -parse-as-library \
  -target arm64-apple-macos26.0 \
  -default-isolation MainActor -enable-bare-slash-regex \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -enable-upcoming-feature DisableOutwardActorInference \
  -o "$BUILD/Float" $(find "$BUILD/src" -name '*.swift')
APP="$BUILD/Float.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Float" "$APP/Contents/MacOS/Float"
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' -e 's/$(EXECUTABLE_NAME)/Float/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.alexk.float/' Float/Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Float/Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sign with a stable local identity (ad-hoc changes every build).
# Override with FLOAT_SIGN_IDENTITY; falls back to ad-hoc when the identity is missing.
IDENTITY="${FLOAT_SIGN_IDENTITY:-Float Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "note: signing identity '$IDENTITY' not found; signing ad-hoc" >&2
  codesign --force --sign - "$APP"
fi
mkdir -p build && rm -rf build/Float.app && cp -R "$APP" build/Float.app
echo "built: $PWD/build/Float.app"
if [[ "$1" == "--install" ]]; then
  pkill -x Float 2>/dev/null || true; sleep 1
  A=~/Applications/Float.app
  rm -rf "$A" && cp -R build/Float.app "$A"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A"
  echo "installed: $A"
fi
