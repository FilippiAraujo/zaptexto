#!/bin/zsh
# Compila o ZapTexto e instala em ~/Applications/ZapTexto.app
set -e
cd "$(dirname "$0")"
APP=build/ZapTexto.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/ZapTexto" 2>&1 | grep -v warning: || true
test -x "$APP/Contents/MacOS/ZapTexto"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.zaptexto</string>
  <key>CFBundleName</key><string>ZapTexto</string>
  <key>CFBundleExecutable</key><string>ZapTexto</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSSpeechRecognitionUsageDescription</key><string>Para transcrever os áudios do WhatsApp no próprio Mac.</string>
</dict></plist>
EOF
codesign --force -s - "$APP"
pkill -x ZapTexto 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/ZapTexto.app
cp -R "$APP" ~/Applications/
echo "instalado em ~/Applications/ZapTexto.app"
