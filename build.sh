#!/bin/zsh
# Builds ZapTexto.app (universal: Apple Silicon + Intel).
#   ./build.sh            build and install to ~/Applications
#   ./build.sh --release  build and create build/ZapTexto.zip (no install)
set -e
cd "$(dirname "$0")"

VERSION=1.1.0
APP=build/ZapTexto.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ compiling"
for arch in arm64 x86_64; do
  swiftc -O main.swift OggOpus.swift -target $arch-apple-macos26.0 -o build/ZapTexto-$arch 2>&1 | grep -v "warning:" || true
  test -f build/ZapTexto-$arch
done
lipo -create build/ZapTexto-arm64 build/ZapTexto-x86_64 -output "$APP/Contents/MacOS/ZapTexto"
rm build/ZapTexto-*

echo "→ icon"
swift scripts/make-icon.swift build
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.filippiaraujo.zaptexto</string>
  <key>CFBundleName</key><string>ZapTexto</string>
  <key>CFBundleDisplayName</key><string>ZapTexto</string>
  <key>CFBundleExecutable</key><string>ZapTexto</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>ZapTexto transcribes WhatsApp voice messages on this Mac.</string>
</dict></plist>
EOF

# Sign with a stable certificate when available (see scripts/make-signing-cert.sh),
# so macOS keeps Full Disk Access across builds. Falls back to ad-hoc.
SIGN_ID="ZapTexto Local Signing"
SIGN_KC=~/Library/Keychains/zaptexto-signing.keychain-db
if [[ -f $SIGN_KC ]] && security find-identity -p codesigning $SIGN_KC | grep -q "$SIGN_ID"; then
  security unlock-keychain -p "$(security find-generic-password -s zaptexto-signing-keychain -w)" $SIGN_KC
  codesign --force --keychain $SIGN_KC -s "$SIGN_ID" "$APP"
  echo "→ signed with '$SIGN_ID'"
else
  codesign --force -s - "$APP"
  echo "→ ad-hoc signed (run scripts/make-signing-cert.sh to keep permissions across builds)"
fi

if [[ "$1" == "--release" ]]; then
  (cd build && ditto -c -k --norsrc --noextattr --noacl --keepParent ZapTexto.app ZapTexto.zip)
  echo "✓ build/ZapTexto.zip"
else
  pkill -x ZapTexto 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/ZapTexto.app
  cp -R "$APP" ~/Applications/
  echo "✓ installed to ~/Applications/ZapTexto.app"
fi
