#!/bin/bash

FRAMEWORK_NAME="WfmCameraPlugin"
OUTPUT_DIR="build"

echo "🔨 开始编译 Framework..."

# 清理旧文件
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Modules"

# 编译真机版本 (arm64)
echo "📱 编译真机版本..."
swiftc -emit-library \
  -o "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
  -module-name "$FRAMEWORK_NAME" \
  -emit-objc-header \
  -emit-objc-header-path "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers/$FRAMEWORK_NAME-Swift.h" \
  Sources/*.swift \
  -target arm64-apple-ios13.0 \
  -sdk $(xcrun --sdk iphoneos --show-sdk-path) \
  -framework UIKit \
  -framework AVFoundation \
  -framework CoreImage \
  -framework Foundation \
  -Xlinker -install_name -Xlinker "@rpath/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"

# 编译模拟器版本 (x86_64)
echo "💻 编译模拟器版本..."
mkdir -p "$OUTPUT_DIR/simulator"
swiftc -emit-library \
  -o "$OUTPUT_DIR/simulator/$FRAMEWORK_NAME" \
  -module-name "$FRAMEWORK_NAME" \
  Sources/*.swift \
  -target x86_64-apple-ios13.0-simulator \
  -sdk $(xcrun --sdk iphonesimulator --show-sdk-path) \
  -framework UIKit \
  -framework AVFoundation \
  -framework CoreImage \
  -framework Foundation || true

# 创建 Info.plist
echo "📝 创建 Info.plist..."
cat > "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Info.plist" <<EOF
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

# 创建 Module Map
echo "📦 创建 Module Map..."
cat > "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Modules/module.modulemap" <<EOF
framework module $FRAMEWORK_NAME {
    header "$FRAMEWORK_NAME-Swift.h"
    export *
}
EOF

# 创建通用二进制（如果模拟器版本编译成功）
if [ -f "$OUTPUT_DIR/simulator/$FRAMEWORK_NAME" ]; then
    echo "🔄 创建通用二进制..."
    lipo -create \
        "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
        "$OUTPUT_DIR/simulator/$FRAMEWORK_NAME" \
        -output "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"
fi

# 创建 ZIP 包
echo "📦 创建 ZIP 包..."
cd "$OUTPUT_DIR"
zip -r "$FRAMEWORK_NAME.framework.zip" "$FRAMEWORK_NAME.framework/"
cd ..

echo "✅ 编译完成！"
echo "📁 Framework 位置: $OUTPUT_DIR/$FRAMEWORK_NAME.framework"
echo "📦 ZIP 包位置: $OUTPUT_DIR/$FRAMEWORK_NAME.framework.zip"