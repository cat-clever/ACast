#!/bin/bash
set -euo pipefail

echo "========================================================="
echo "  ACast iOS 手机端 IPA 打包构建脚本 (支持自签/补签名)"
echo "========================================================="

# 1. 查找并验证 iphoneos SDK
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>/dev/null; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
echo "[1/6] 成功加载 iOS SDK: ${SDK_PATH}"

TARGET="arm64-apple-ios16.0"
VERSION="${1:-0.5.4}"

# 2. 清理并初始化 Payload 目录结构
echo "[2/6] 创建标准 iOS 应用 Bundle 结构..."
rm -rf Payload acast-ios.ipa
mkdir -p Payload/ACast.app/PlugIns/ScreenSenderExtension.appex

# 3. 编译主程序 ACast (基于 Swift / iOS 16+)
echo "[3/6] 编译主应用 arm64 Mach-O 可执行二进制 (ACast)..."
xcrun -sdk iphoneos swiftc \
  -parse-as-library \
  -target "${TARGET}" \
  -sdk "${SDK_PATH}" \
  -O \
  -framework UIKit \
  -framework Foundation \
  -framework AVFoundation \
  -framework ReplayKit \
  -framework VideoToolbox \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework Network \
  -o Payload/ACast.app/ACast \
  app-ios/ScreenSender/AppDelegate.swift

chmod +x Payload/ACast.app/ACast

# 4. 编译 ReplayKit 屏幕广播扩展 (ScreenSenderExtension)
echo "[4/6] 编译 ReplayKit 2 屏幕广播扩展 (ScreenSenderExtension)..."
xcrun -sdk iphoneos swiftc \
  -parse-as-library \
  -application-extension \
  -target "${TARGET}" \
  -sdk "${SDK_PATH}" \
  -O \
  -framework ReplayKit \
  -framework Foundation \
  -framework VideoToolbox \
  -framework CoreMedia \
  -framework CoreVideo \
  -Xlinker -e \
  -Xlinker _NSExtensionMain \
  -o Payload/ACast.app/PlugIns/ScreenSenderExtension.appex/ScreenSenderExtension \
  app-ios/ScreenSenderExtension/SampleHandler.swift

chmod +x Payload/ACast.app/PlugIns/ScreenSenderExtension.appex/ScreenSenderExtension

# 5. 生成标准 Info.plist 与图标资源 (包含 iOS 14+ 局域网权限、摄像头权限、后台持续运行与全屏 LaunchScreen)
echo "[5/6] 生成主应用与扩展的标准 Info.plist 配置..."

cat << EOF > Payload/ACast.app/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ACast</string>
    <key>CFBundleIdentifier</key>
    <string>com.catclever.acast</string>
    <key>CFBundleName</key>
    <string>ACast</string>
    <key>CFBundleDisplayName</key>
    <string>ACast</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>MinimumOSVersion</key>
    <string>16.0</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ACast 需要访问本地局域网，用于自动发现电脑控制端并通过 FastMirror 私有协议进行极低延迟无线投屏与相机推流。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_acast._tcp</string>
        <string>_acast._udp</string>
    </array>
    <key>NSCameraUsageDescription</key>
    <string>ACast 需要访问摄像头，用于将 iPhone 高清摄像头画面实时无线推流至电脑与虚拟摄像头。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>ACast 需要访问麦克风以支持音视频同步传输。</string>
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
        <string>processing</string>
    </array>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>AppIcon</string>
            </array>
            <key>CFBundleIconName</key>
            <string>AppIcon</string>
        </dict>
    </dict>
</dict>
</plist>
EOF

cat << EOF > Payload/ACast.app/PlugIns/ScreenSenderExtension.appex/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ScreenSenderExtension</string>
    <key>CFBundleIdentifier</key>
    <string>com.catclever.acast.ScreenSenderExtension</string>
    <key>CFBundleName</key>
    <string>ScreenSenderExtension</string>
    <key>CFBundleDisplayName</key>
    <string>ACast 屏幕广播</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>MinimumOSVersion</key>
    <string>16.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ACast 屏幕广播扩展需要访问本地网络以传输实时屏幕视频流。</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.broadcast-services-upload</string>
        <key>NSExtensionPrincipalClass</key>
        <string>ScreenSenderExtension.SampleHandler</string>
        <key>RPBroadcastProcessMode</key>
        <string>RPBroadcastProcessModeSampleBuffer</string>
    </dict>
</dict>
</plist>
EOF

if [ -f "app-ios/ScreenSender/AppIcon.png" ]; then
    cp app-ios/ScreenSender/AppIcon.png Payload/ACast.app/AppIcon.png
    cp app-ios/ScreenSender/AppIcon.png Payload/ACast.app/AppIcon60x60@2x.png
    cp app-ios/ScreenSender/AppIcon.png Payload/ACast.app/AppIcon60x60@3x.png
fi

# 6. Ad-hoc 签名与压缩封装为标准 .ipa
echo "[6/6] 进行基础 Ad-hoc 签名并封装为标准 .ipa 安装包..."
codesign --force --sign - --timestamp=none Payload/ACast.app/PlugIns/ScreenSenderExtension.appex
codesign --force --sign - --timestamp=none Payload/ACast.app

zip -qr acast-ios.ipa Payload
rm -rf Payload

echo "✅ 成功生成补签名专用 iOS 安装包: acast-ios.ipa ($(ls -lh acast-ios.ipa | awk '{print $5}'))"
