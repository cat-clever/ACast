#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_BUILD_DIR="${PROJECT_ROOT}/build/camera-extension"
BUNDLE_NAME="com.clevercat.acast.camera-extension.systemextension"
SOURCE_BUNDLE="${EXT_BUILD_DIR}/${BUNDLE_NAME}"
APP_PATH="/Applications/ACast.app"
DEST_EXT_DIR="${APP_PATH}/Contents/Library/SystemExtensions"

echo "=========================================================="
echo "  [ACast] 安装 macOS CoreMediaIO 相机扩展"
echo "=========================================================="

if [ ! -d "${SOURCE_BUNDLE}" ]; then
    echo "• 正在编译最新通用架构相机扩展..."
    "${PROJECT_ROOT}/scripts/build_camera_extension.sh" "${EXT_BUILD_DIR}"
fi

if [ -d "${APP_PATH}" ]; then
    echo "• 将扩展打包进应用程序: ${DEST_EXT_DIR}..."
    mkdir -p "${DEST_EXT_DIR}"
    rm -rf "${DEST_EXT_DIR}/${BUNDLE_NAME}"
    cp -R "${SOURCE_BUNDLE}" "${DEST_EXT_DIR}/"
    codesign --force --sign - --timestamp=none "${DEST_EXT_DIR}/${BUNDLE_NAME}/Contents/MacOS/ACastCameraExtension"
    codesign --force --deep --sign - --timestamp=none "${DEST_EXT_DIR}/${BUNDLE_NAME}"
    echo "✓ 相机扩展已嵌入 /Applications/ACast.app"
fi

echo ""
echo "• 检查系统扩展运行状态 (systemextensionsctl)..."
systemextensionsctl list || true

echo ""
echo "=========================================================="
echo "  🎉 安装配置就绪！"
echo "  提示指引："
echo "  1. 若 macOS 弹出【系统扩展已阻止】提示："
echo "     请打开【系统设置 > 通用 > 登录项与扩展 > 相机扩展】"
echo "     找到并勾选启用【ACast】即可；"
echo "  2. 随后在 Zoom、FaceTime、腾讯会议、Photo Booth 等任意应用中，"
echo "     直接在摄像头列表中选用对应的虚拟相机即可实时呈现 Android 画面！"
echo "=========================================================="

