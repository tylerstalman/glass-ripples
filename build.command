#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple Command Line Tools are required."
    echo "Opening Apple's installer. Finish installation, then run this file again."
    /usr/bin/xcode-select --install || true
    exit 1
fi
DEST="$PWD/Glass Ripples.app"
STAGE="$(mktemp -d "$PWD/.glass-build.XXXXXX")"
APP="$STAGE/Glass Ripples.app"
CACHE="$STAGE/cache"
cleanup() {
    if [[ -d "$STAGE/previous.app" && ! -e "$DEST" ]]; then mv "$STAGE/previous.app" "$DEST"; fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir -p "$CACHE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/xcrun clang -O2 -target arm64-apple-macosx14.0 -c Sources/TouchInput.c -o "$CACHE/TouchInput.o"
/usr/bin/xcrun clang -O2 -target arm64-apple-macosx14.0 -c Sources/GridDecoder.c -o "$CACHE/GridDecoder.o"
/usr/bin/xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
    -module-cache-path "${GR_MODULE_CACHE:-$CACHE}" \
    -import-objc-header Sources/TouchInput.h \
    -framework AppKit -framework MetalKit -framework ScreenCaptureKit \
    -framework CoreMedia -framework Carbon -framework IOKit \
    Sources/main.swift "$CACHE/TouchInput.o" "$CACHE/GridDecoder.o" -o "$APP/Contents/MacOS/GlassRipples"
cp Sources/Ripple.metal "$APP/Contents/Resources/Ripple.metal"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GlassRipples</string>
<key>CFBundleIdentifier</key><string>com.local.glassripples</string>
<key>CFBundleName</key><string>Glass Ripples</string>
<key>CFBundleDisplayName</key><string>Glass Ripples</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.2</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
if [[ -e "$DEST" ]]; then mv "$DEST" "$STAGE/previous.app"; fi
mv "$APP" "$DEST"
cp Sources/Ripple.metal "${TMPDIR:-/tmp/}GlassRipples-Ripple.metal"
echo "Built: $DEST"
if [[ "${1:-}" != "--no-open" ]]; then
    if ! /usr/bin/open "$DEST"; then
        echo "Automatic launch failed. Open Glass Ripples.app directly from Finder."
    fi
fi
