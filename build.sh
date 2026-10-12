#!/bin/bash
# Builds Meerkat.app. No Xcode project, no package manifest — just swiftc and a
# hand-written bundle, because this is one small binary.
#
#   ./build.sh
#
# Produces build/Meerkat.app. Needs the Xcode command line tools:
#   xcode-select --install

set -euo pipefail
cd "$(dirname "$0")"

APP="build/Meerkat.app"
BIN="$APP/Contents/MacOS/Meerkat"

if ! command -v swiftc >/dev/null 2>&1; then
  cat >&2 <<'MSG'
swiftc was not found.

Install the Xcode command line tools and try again:

    xcode-select --install

That is a one-time download of a few GB. A full Xcode install is not needed.
MSG
  exit 1
fi

echo "Building with $(swiftc --version 2>&1 | head -1)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Pin the deployment target so the LSMinimumSystemVersion in Info.plist below is
# actually true. Without this, swiftc targets whatever macOS built it and the app
# is rejected on anything older.
swiftc -O \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Carbon \
  Sources/Models.swift \
  Sources/UsageFetcher.swift \
  Sources/SessionStore.swift \
  Sources/Critter.swift \
  Sources/ContentView.swift \
  Sources/PanelController.swift \
  Sources/HotKey.swift \
  Sources/StatusItem.swift \
  Sources/main.swift \
  -o "$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Meerkat</string>
    <key>CFBundleDisplayName</key>
    <string>Meerkat</string>
    <key>CFBundleExecutable</key>
    <string>Meerkat</string>
    <key>CFBundleIdentifier</key>
    <string>local.meerkat.widget</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- A widget, not an app you switch to: no Dock icon, no app switcher. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for a locally built app to run and to keep its
# UserDefaults (window position, mute) across rebuilds.
codesign --force --sign - "$APP" >/dev/null 2>&1 || {
  echo "note: ad-hoc codesign failed; the app will still run" >&2
}

echo
echo "Built $APP"
echo
echo "Run it with:    open $APP"
echo "Stop it with:   right-click the window -> Quit Meerkat"
