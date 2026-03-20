#!/bin/bash
set -e  # 任何命令失败就退出
set -x  # 显示执行的命令

FRAMEWORK_NAME="WfmCameraPlugin"
OUTPUT_DIR="build"

echo "🔨 开始编译 Framework..."

# 清理旧文件
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers"
mkdir -p "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Modules"

# 检查Swift文件
echo "检查源文件..."
if [ ! -d "Sources" ]; then
    echo "❌ 错误：找不到 Sources 目录"
    exit 1
fi

if [ ! -f "Sources/WfmCameraPlugin.swift" ]; then
    echo "❌ 错误：找不到 Sources/WfmCameraPlugin.swift"
    echo "当前Sources目录内容："
    ls -la Sources/
    exit 1
fi

echo "✅ 找到源文件，内容预览："
head -20 Sources/WfmCameraPlugin.swift

# 获取Xcode路径
XCODE_PATH=$(xcode-select -p)
echo "Xcode路径: $XCODE_PATH"

# 获取iOS SDK路径
IPHONE_SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")
if [ -z "$IPHONE_SDK" ]; then
    echo "❌ 无法找到iOS SDK"
    exit 1
fi
echo "iOS SDK路径: $IPHONE_SDK"

# 编译前检查
echo "检查依赖框架..."
for framework in UIKit AVFoundation CoreImage Foundation; do
    if [ -f "$IPHONE_SDK/System/Library/Frameworks/${framework}.framework/${framework}" ] || \
       [ -d "$IPHONE_SDK/System/Library/Frameworks/${framework}.framework" ]; then
        echo "✅ 找到 $framework"
    else
        echo "⚠️ 警告：可能找不到 $framework"
    fi
done

# 第一步：先检查语法
echo "🔍 检查语法..."
swiftc -typecheck \
    Sources/WfmCameraPlugin.swift \
    -target arm64-apple-ios13.0 \
    -sdk "$IPHONE_SDK" \
    -F "$IPHONE_SDK/System/Library/Frameworks"

if [ $? -ne 0 ]; then
    echo "❌ 语法检查失败"
    exit 1
fi
echo "✅ 语法检查通过"

# 第二步：编译为对象文件
echo "🏗️ 编译为对象文件..."
mkdir -p build/obj
swiftc -c \
    Sources/WfmCameraPlugin.swift \
    -module-name "$FRAMEWORK_NAME" \
    -target arm64-apple-ios13.0 \
    -sdk "$IPHONE_SDK" \
    -F "$IPHONE_SDK/System/Library/Frameworks" \
    -emit-objc-header \
    -emit-objc-header-path "build/obj/$FRAMEWORK_NAME-Swift.h" \
    -o "build/obj/$FRAMEWORK_NAME.o"

if [ $? -ne 0 ]; then
    echo "❌ 编译为对象文件失败"
    exit 1
fi
echo "✅ 对象文件编译成功"

# 第三步：链接为动态库
echo "🔗 链接动态库..."
swiftc -emit-library \
    -o "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
    -module-name "$FRAMEWORK_NAME" \
    "build/obj/$FRAMEWORK_NAME.o" \
    -target arm64-apple-ios13.0 \
    -sdk "$IPHONE_SDK" \
    -F "$IPHONE_SDK/System/Library/Frameworks" \
    -framework UIKit \
    -framework AVFoundation \
    -framework CoreImage \
    -framework Foundation \
    -Xlinker -install_name -Xlinker "@rpath/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"

if [ $? -ne 0 ]; then
    echo "❌ 链接失败"
    exit 1
fi
echo "✅ 链接成功"

# 第四步：复制头文件
cp "build/obj/$FRAMEWORK_NAME-Swift.h" "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Headers/"

# 第五步：创建 Info.plist
echo "📝 创建 Info.plist..."
cat > "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>WfmCameraPlugin</string>
    <key>CFBundleIdentifier</key>
    <string>com.wfm.WfmCameraPlugin</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>WfmCameraPlugin</string>
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

# 第六步：创建 Module Map
echo "📦 创建 Module Map..."
cat > "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/Modules/module.modulemap" <<EOF
framework module $FRAMEWORK_NAME {
    header "$FRAMEWORK_NAME-Swift.h"
    export *
}
EOF

# 第七步：验证生成的二进制文件
echo "🔍 验证生成的二进制文件..."
if [ ! -f "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" ]; then
    echo "❌ 二进制文件未生成"
    exit 1
fi

FILE_SIZE=$(wc -c < "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME")
echo "二进制文件大小: $FILE_SIZE bytes"

if [ $FILE_SIZE -lt 100000 ]; then  # 小于100KB可能有问题
    echo "⚠️ 警告：二进制文件可能太小 ($FILE_SIZE bytes)"
fi

file "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"

# 第八步：创建ZIP包
echo "📦 创建 ZIP 包..."
cd "$OUTPUT_DIR"
zip -r "$FRAMEWORK_NAME.framework.zip" "$FRAMEWORK_NAME.framework/"
cd ..

echo "✅ 编译完成！"
echo "最终文件大小："
ls -lh "$OUTPUT_DIR/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"
ls -lh "$OUTPUT_DIR/$FRAMEWORK_NAME.framework.zip"
