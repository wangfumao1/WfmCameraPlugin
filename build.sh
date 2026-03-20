#!/bin/bash
set -e

FRAMEWORK_NAME="WfmCameraPlugin"
OUTPUT_DIR="build"

echo "🔨 编译..."

# 清理
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers"

# 获取 SDK
IPHONE_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

# 编译
clang -arch arm64 \
    -isysroot "$IPHONE_SDK" \
    -framework Foundation \
    -fobjc-arc \
    -I Sources \
    -c Sources/WfmCameraPlugin.m \
    -o "$OUTPUT_DIR/WfmCameraPlugin.o"

# 创建静态库
ar rcs "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" "$OUTPUT_DIR/WfmCameraPlugin.o"

# 复制头文件
cp Sources/WfmCameraPlugin.h "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers/"

# 创建 Info.plist
cat > "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.test.$FRAMEWORK_NAME</string>
    <key>CFBundleName</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF

plutil -convert binary1 "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Info.plist"

# 打包
cd "$OUTPUT_DIR"
zip -r "$FRAMEWORK_NAME.framework.zip" "$FRAMEWORK_NAME.framework/"
cd ..

echo "✅ 完成！"
