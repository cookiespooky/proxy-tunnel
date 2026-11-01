#!/bin/bash
# Собирает «Proxy Tunnel.app» (Intel + Apple Silicon) в menubar/build/ рядом с этим файлом.
set -e
cd "$(dirname "$0")"
APP="build/Proxy Tunnel.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS"
for arch in x86_64 arm64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" Config.swift Tunnel.swift Model.swift Views.swift -o "build/tunnel-$arch"
done
lipo -create build/tunnel-x86_64 build/tunnel-arm64 -output "$APP/Contents/MacOS/ProxyTunnel"
rm build/tunnel-*
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ru.antonlozhkin.proxy-tunnel</string>
  <key>CFBundleName</key><string>Proxy Tunnel</string>
  <key>CFBundleExecutable</key><string>ProxyTunnel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Собрано: $(pwd)/$APP"
