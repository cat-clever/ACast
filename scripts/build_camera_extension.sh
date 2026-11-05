#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_SRC_DIR="${PROJECT_ROOT}/extensions/mac-camera-extension"
OUT_DIR="${1:-${PROJECT_ROOT}/build/camera-extension}"
BUNDLE_NAME="com.clevercat.acast.camera-extension.systemextension"
TARGET_BUNDLE="${OUT_DIR}/${BUNDLE_NAME}"

echo "=========================================================="
echo "  [ACast] 开始构建 macOS CoreMediaIO 虚拟摄像头扩展..."
echo "=========================================================="

mkdir -p "${OUT_DIR}"
TEMP_BUILD_DIR="${OUT_DIR}/temp"
mkdir -p "${TEMP_BUILD_DIR}"

SWIFT_SOURCES=(
    "${EXT_SRC_DIR}/main.swift"
    "${EXT_SRC_DIR}/ACastCameraExtension.swift"
)

FRAMEWORKS=(
    "-framework" "CoreMediaIO"
    "-framework" "CoreMedia"
    "-framework" "CoreVideo"
    "-framework" "CoreGraphics"
    "-framework" "Foundation"
)

echo "1. 编译 arm64 架构二进制..."
swiftc -target arm64-apple-macosx12.3 -O "${FRAMEWORKS[@]}" "${SWIFT_SOURCES[@]}" -o "${TEMP_BUILD_DIR}/ext_arm64"

echo "2. 编译 x86_64 架构二进制..."
swiftc -target x86_64-apple-macosx12.3 -O "${FRAMEWORKS[@]}" "${SWIFT_SOURCES[@]}" -o "${TEMP_BUILD_DIR}/ext_x86_64"

echo "3. 合成 Universal 2 通用二进制 (arm64 + x86_64)..."
lipo -create "${TEMP_BUILD_DIR}/ext_arm64" "${TEMP_BUILD_DIR}/ext_x86_64" -output "${TEMP_BUILD_DIR}/ACastCameraExtension"

echo "4. 组装 SystemExtension Bundle 结构..."
rm -rf "${TARGET_BUNDLE}"
mkdir -p "${TARGET_BUNDLE}/Contents/MacOS"
cp "${TEMP_BUILD_DIR}/ACastCameraExtension" "${TARGET_BUNDLE}/Contents/MacOS/ACastCameraExtension"
chmod +x "${TARGET_BUNDLE}/Contents/MacOS/ACastCameraExtension"
cp "${EXT_SRC_DIR}/Info.plist" "${TARGET_BUNDLE}/Contents/Info.plist"

echo "5. 执行签名验证 (Ad-Hoc 签名)..."
codesign --force --sign - --timestamp=none "${TARGET_BUNDLE}/Contents/MacOS/ACastCameraExtension"
codesign --force --deep --sign - --timestamp=none "${TARGET_BUNDLE}"

rm -rf "${TEMP_BUILD_DIR}"

echo "=========================================================="
echo "  ✓ 摄像头扩展已就绪: ${TARGET_BUNDLE}"
echo "=========================================================="
