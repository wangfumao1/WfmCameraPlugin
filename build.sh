#!/bin/bash
set -e

FRAMEWORK_NAME="WfmCameraPlugin"
OUTPUT_DIR="build"

echo "🔨 开始编译静态 Framework..."

# 清理
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework"

# 获取 SDK
IPHONE_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

# 编译为静态库（.a）
echo "编译静态库..."
swiftc -static \
    Sources/*.swift \
    -module-name "$FRAMEWORK_NAME" \
    -target arm64-apple-ios13.0 \
    -sdk "$IPHONE_SDK" \
    -emit-library \
    -o "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
    -Xlinker -rpath -Xlinker @loader_path/Frameworks

# 创建 Info.plist（二进制格式）
echo "创建 Info.plist..."
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

# 打包
cd "$OUTPUT_DIR"
zip -r "$FRAMEWORK_NAME.framework.zip" "$FRAMEWORK_NAME.framework/"
cd ..

echo "✅ 完成！"
ls -lh "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"
