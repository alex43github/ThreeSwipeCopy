#!/bin/bash
# 构建 ThreeSwipeCopy.app（无需 Xcode，仅需 Command Line Tools）
# 使用固定自签名证书签名，授权一次后重装不会失效
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ThreeSwipeCopy"
BUNDLE_ID="com.niangao.ThreeSwipeCopy"
SIGN_IDENTITY="ThreeSwipeCopy Developer"
BIN=".build/release/$APP_NAME"
APP_DIR="dist/$APP_NAME.app"

echo "==> [1/3] swift build -c release"
swift build -c release

echo "==> [2/3] 组装 .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>三指复制粘贴</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>个人使用</string>
</dict>
</plist>
PLIST

echo "==> [3/3] 固定证书签名 ($SIGN_IDENTITY)"
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep "$APP_DIR" && echo "签名验证通过"

echo ""
echo "构建完成：$PWD/$APP_DIR"
echo "运行安装脚本 install.sh 复制到 /Applications 并启动。"
