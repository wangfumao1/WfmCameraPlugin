#!/bin/bash
set -e
set -x

FRAMEWORK_NAME="WfmCameraPlugin"
OUTPUT_DIR="build"

echo "🔨 开始编译..."

# 清理旧文件
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers"

# 解压 SDK 头文件
echo "📦 解压 SDK 头文件..."
if [ -f "inc.zip" ]; then
    unzip -o inc.zip
    echo "✅ inc.zip 解压完成"
else
    echo "❌ 找不到 inc.zip"
    exit 1
fi

# 检查头文件是否存在
if [ ! -f "inc/DCUni/DCUniModule.h" ]; then
    echo "❌ 找不到 inc/DCUni/DCUniModule.h"
    ls -la inc/
    exit 1
fi
echo "✅ 找到 DCUniModule.h"

# 获取 iOS SDK 路径
IPHONE_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "iOS SDK: $IPHONE_SDK"

# 编译 Objective-C 代码（修复空格问题）
echo "🔨 编译 Objective-C 代码..."
clang -arch arm64 \
    -isysroot "$IPHONE_SDK" \
    -I "./inc/DCUni" \
    -I "./inc/weexHeader" \
    -I "./inc" \
    -fobjc-arc \
    -c "./Sources/WfmCameraPlugin.m" \
    -o "$OUTPUT_DIR/WfmCameraPlugin.o"

# 检查编译是否成功
if [ $? -ne 0 ]; then
    echo "❌ 编译失败"
    exit 1
fi

# 创建静态库
echo "📚 创建静态库..."
ar rcs "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" "$OUTPUT_DIR/WfmCameraPlugin.o"

# 复制头文件
cp "./Sources/WfmCameraPlugin.h" "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers/"

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

# 转换为二进制格式
plutil -convert binary1 "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Info.plist"

# 打包
cd "$OUTPUT_DIR"
zip -r "$FRAMEWORK_NAME.framework.zip" "$FRAMEWORK_NAME.framework/"
cd ..

echo "✅ 编译完成！"
echo "最终文件大小："
ls -lh "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"
ls -lh "$OUTPUT_DIR/$FRAMEWORK_NAME.framework.zip"
