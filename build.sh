#!/bin/bash

FRAMEWORK_NAME="WfmCameraPlugin"
OUTPUT_DIR="build"

echo "🔨 开始编译 Framework..."

# 清理旧文件
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Modules"

# 获取SDK路径
IPHONE_SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
echo "使用SDK: $IPHONE_SDK"

# 编译真机版本
echo "📱 编译真机版本..."
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

# 检查结果
if [ $? -eq 0 ]; then
    echo "✅ 编译成功"
    file "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"
else
    echo "❌ 编译失败"
    exit 1
fi

# 创建 Info.plist（同上）
# 创建 Module Map（同上）
# 创建 ZIP 包（同上）
