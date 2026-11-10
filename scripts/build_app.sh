#!/bin/bash
# Build the apps as universal (arm64 + x86_64) binaries into dist/:
#   Touch SD.app      the product (with the sudo PAM module inside), and Touch SD.dmg
# Needs vendor/opencv from scripts/build_opencv.sh.
#
# Signing: with the first "Apple Development" identity in the keychain (or SIGN_ID=...),
# so every build keeps the same code identity and the keychain's "Always Allow" sticks;
# an ad-hoc build is a new program to the keychain each time and asks again.  Without
# such a certificate it falls back to ad-hoc.  For other Macs: Developer ID + notarize.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION 2>/dev/null || echo 0.1)
ARCHS=(--arch arm64 --arch x86_64)
mkdir -p dist .build/icons .build/pam
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
SIGN_ID=${SIGN_ID:--}
echo "== signing identity: $SIGN_ID"
sign() { codesign --force --options runtime --sign "$SIGN_ID" --timestamp=none "$@"; }

echo "== Swift (universal)"
for p in SDFinger fingerconfirm; do
    if ! swift build -c release "${ARCHS[@]}" --product "$p" > .build/swift.log 2>&1; then
        grep -E "error" .build/swift.log
        exit 1
    fi
done
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

echo "== PAM module"
clang -Wall -Wextra -O2 -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -o .build/pam/pam_sdfinger.so.2 pam/pam_sdfinger.c -lpam -framework Security -framework CoreFoundation

echo "== icons"
for kind in product; do
    if [ ! -f ".build/icons/$kind.icns" ] || [ scripts/make_icon.swift -nt ".build/icons/$kind.icns" ]; then
        rm -rf ".build/icons/$kind.iconset"
        swift scripts/make_icon.swift ".build/icons/$kind.iconset" "$kind"
        iconutil -c icns ".build/icons/$kind.iconset" -o ".build/icons/$kind.icns"
    fi
done

bundle() {  # name exe bundle-id icon
    local name=$1 exe=$2 id=$3 icon=$4
    local app="dist/$name.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN/$exe" "$app/Contents/MacOS/$exe"
    cp ".build/icons/$icon.icns" "$app/Contents/Resources/AppIcon.icns"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>$id</string>
    <key>CFBundleExecutable</key><string>$exe</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>NSRemovableVolumesUsageDescription</key><string>和插在卡槽里的 Touch SD 指纹卡通信。</string>
    <key>NSAppleEventsUsageDescription</key><string>安装或移除 sudo 指纹模块时请求管理员权限。</string>
</dict>
</plist>
PLIST
}

echo "== bundles"
bundle "Touch SD" SDFinger com.pico-fp-touch.sdfinger product
cp .build/pam/pam_sdfinger.so.2 "dist/Touch SD.app/Contents/Resources/"
sign "dist/Touch SD.app/Contents/Resources/pam_sdfinger.so.2"
cp "$BIN/fingerconfirm" "dist/Touch SD.app/Contents/Resources/"
sign "dist/Touch SD.app/Contents/Resources/fingerconfirm"
sign "dist/Touch SD.app"

echo "== dmg"
STAGE=.build/dmg
rm -rf "$STAGE" "dist/Touch SD.dmg"
mkdir -p "$STAGE"
cp -R "dist/Touch SD.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Touch SD" -srcfolder "$STAGE" -format UDZO "dist/Touch SD.dmg"

lipo -info "dist/Touch SD.app/Contents/MacOS/SDFinger"
shasum -a 256 "dist/Touch SD.dmg"
echo "built dist/Touch SD.app, dist/Touch SD.dmg ($VERSION)"
