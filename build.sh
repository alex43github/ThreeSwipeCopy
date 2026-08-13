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
APP_DIR="dist/$APP_NAME.app"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tsc-build.XXXXXX")"
TMP_APP="$TMP_ROOT/$APP_NAME.app"
SWIFTPM_SCRATCH="$TMP_ROOT/swiftpm-scratch"
SWIFT_MODULE_CACHE="$TMP_ROOT/swift-module-cache"
CLANG_MODULE_CACHE="$TMP_ROOT/clang-module-cache"
mkdir -p "$SWIFT_MODULE_CACHE" "$CLANG_MODULE_CACHE"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "==> [1/3] swift build -c release"
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE" \
SWIFT_MODULECACHE_PATH="$SWIFT_MODULE_CACHE" \
swift build -c release --scratch-path "$SWIFTPM_SCRATCH" \
	--disable-sandbox --disable-build-manifest-caching \
	-Xswiftc -module-cache-path -Xswiftc "$SWIFT_MODULE_CACHE"
BIN="$(swift build -c release --show-bin-path --scratch-path "$SWIFTPM_SCRATCH")/$APP_NAME"

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
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""; then
	# 固定证书存在时使用它，避免每次重装都触发辅助功能重新授权。
	codesign --force --deep --sign "$SIGN_IDENTITY" "$TMP_APP"
	SIGN_MODE="固定证书"
else
	# 证书可能因钥匙串迁移、重装系统或清理开发证书而消失；
	# ad-hoc 签名仍可让 LaunchAgent 启动，避免应用静默失效。
	codesign --force --deep --sign - "$TMP_APP"
	SIGN_MODE="临时 ad-hoc 签名（未找到 $SIGN_IDENTITY）"
fi
codesign --verify --deep "$TMP_APP" && echo "签名验证通过"

echo "==> 拷贝到 dist（去掉 xattr）"
rm -rf "$APP_DIR"
ditto --noextattr "$TMP_APP" "$APP_DIR"

echo ""
echo "构建完成：$PWD/$APP_DIR"
echo "签名模式：$SIGN_MODE"
echo "运行安装脚本 install.sh 复制到 /Applications 并启动。"
