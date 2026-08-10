#!/bin/bash
# 构建 ThreeSwipeCopy.app（无需 Xcode，仅需 Command Line Tools）
# 使用固定自签名证书签名，授权一次后重装不会失效
# 注意：在 /tmp 临时目录组装并签名，再拷入 dist —— 避免 iCloud 同步目录的
# com.apple.FinderInfo / fileprovider 等 xattr 导致 codesign 报
# "resource fork, Finder information, or similar detritus not allowed" 而失败。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ThreeSwipeCopy"
BUNDLE_ID="com.niangao.ThreeSwipeCopy"
SIGN_IDENTITY="ThreeSwipeCopy Developer"
BIN=".build/release/$APP_NAME"
APP_DIR="dist/$APP_NAME.app"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tsc-build.XXXXXX")"
TMP_APP="$TMP_ROOT/$APP_NAME.app"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "==> [1/3] swift build -c release"
swift build -c release

echo "==> [2/3] 组装 .app bundle（临时目录，避开 iCloud xattr）"
mkdir -p "$TMP_APP/Contents/MacOS" "$TMP_APP/Contents/Resources"
cp "$BIN" "$TMP_APP/Contents/MacOS/$APP_NAME"

cat > "$TMP_APP/Contents/Info.plist" <<PLIST
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
xattr -cr "$TMP_APP" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" "$TMP_APP"
codesign --verify --deep "$TMP_APP" && echo "签名验证通过"

echo "==> 拷贝到 dist（去掉 xattr）"
rm -rf "$APP_DIR"
ditto --noextattr "$TMP_APP" "$APP_DIR"

echo ""
echo "构建完成：$PWD/$APP_DIR"
echo "运行安装脚本 install.sh 复制到 /Applications 并启动。"
