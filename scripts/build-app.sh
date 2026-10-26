#!/bin/bash
# Builds Measure.app in ./build: a double-clickable app with its own microphone permission.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Measure
BIN="$(swift build -c release --show-bin-path)/Measure"
APP="build/Measure.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Measure"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Measure</string>
    <key>CFBundleDisplayName</key><string>Measure</string>
    <key>CFBundleIdentifier</key><string>local.measure.app</string>
    <key>CFBundleExecutable</key><string>Measure</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Measure records your measurement microphones during a sweep.</string>
    <key>NSLocalNetworkUsageDescription</key><string>Measure lets the Measure Remote app on your iPad control it over the local network.</string>
    <key>NSBonjourServices</key><array><string>_measure-remote._tcp</string></array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>local.measure.set</string>
            <key>UTTypeDescription</key><string>Measurement Set</string>
            <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>measure</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Measurement Set</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSTypeIsPackage</key><true/>
            <key>LSItemContentTypes</key><array><string>local.measure.set</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS remembers the microphone permission between launches.
codesign --force --deep --sign - "$APP"
# Tell Launch Services about the app now, so .measure sets show as files and open in it straight away.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true
echo "Built $APP. Open it with: open $APP"
