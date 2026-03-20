#!/bin/bash
set -e

FRAMEWORK_NAME="WfmCameraPlugin"
OUTPUT_DIR="build"

echo "🔨 开始编译 Framework..."

# 清理旧文件
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Modules"

# 获取 SDK 路径
IPHONE_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "iOS SDK: $IPHONE_SDK"

# 编译
echo "📱 编译..."
swiftc -emit-library \
  -o "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
  -module-name "$FRAMEWORK_NAME" \
  -emit-objc-header \
  -emit-objc-header-path "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers/$FRAMEWORK_NAME-Swift.h" \
  Sources/*.swift \
  -target arm64-apple-ios13.0 \
  -sdk "$IPHONE_SDK" \
  -framework UIKit \
  -framework AVFoundation \
  -framework CoreImage \
  -framework Foundation

echo "✅ 编译完成"

# 创建二进制格式的 Info.plist（关键修复！）
echo "📝 创建二进制 Info.plist..."
cat > /tmp/Info.plist.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.wfm.$FRAMEWORK_NAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>13.0</string>
</dict>
</plist>
EOF

plutil -convert binary1 /tmp/Info.plist.xml -o "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Info.plist"
rm /tmp/Info.plist.xml

# 验证 Info.plist 格式
echo "验证 Info.plist 格式："
file "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Info.plist"
# 应该输出: Info.plist: Apple binary property list

# 创建 Module Map
echo "📦 创建 Module Map..."
cat > "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Modules/module.modulemap" <<EOF
framework module $FRAMEWORK_NAME {
    header "$FRAMEWORK_NAME-Swift.h"
    export *
}
EOF

# 创建 ZIP 包
cd "$OUTPUT_DIR"
zip -r "$FRAMEWORK_NAME.framework.zip" "$FRAMEWORK_NAME.framework/"
cd ..

echo "✅ 编译完成！"
echo "最终文件大小："
ls -lh "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"
ls -lh "$OUTPUT_DIR/$FRAMEWORK_NAME.framework.zip"

# 验证 Info.plist 格式
echo "Info.plist 格式："
file "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Info.plist"
