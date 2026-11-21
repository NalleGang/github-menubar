#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h:h}"
swift build --configuration release
binary_dir=$(swift build --configuration release --show-bin-path)
bundle="$PWD/dist/Git Stage.app"

mkdir -p "$bundle/Contents/MacOS"
install -m 755 "$binary_dir/GitMenuBar" "$bundle/Contents/MacOS/GitMenuBar"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>GitMenuBar</string>
    <key>CFBundleIdentifier</key><string>com.nallegang.github-menubar</string>
    <key>CFBundleName</key><string>Git Stage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle"
codesign --verify "$bundle"
print -r -- "$bundle"
