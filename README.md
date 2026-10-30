# 跨平台多协议投屏与反向控制系统

一套集成了 **“B站/DLNA 免装客户端大屏投屏”** 与 **“Windows/macOS 桌面端 USB/Wi-Fi 极低延迟反向操控（全架构原生支持）”** 的投屏系统。

## 核心架构与多芯片支持
- 💻 **桌面端多架构原生支持（Windows & macOS 控制端）**：
  - **Windows x86_64**：传统 Intel / AMD 64位电脑。
  - **Windows ARM64**：高通骁龙 X Elite 笔记本、Surface Pro ARM 系列、Win11 on ARM，免指令模拟原生最高性能。
  - **macOS Universal 2**：一份包原生支持 Apple Silicon（M1/M2/M3/M4）与 Intel 架构 Mac。
- 📺 **场景一：电视大屏免装软件投屏（B站 / DLNA 协议体系）**：
  - 对标 B 站 / 爱奇艺投屏机制，支持局域网内任意智能电视、电视盒子。
  - 电视端**无需安装任何接收软件**，即搜即投，免密秒连。
- 🎮 **场景二：桌面端极低延迟 & 鼠标键盘反向操控手机（自研 FastMirror 协议）**：
  - 支持 **USB 数据线直连**（15~35ms 极低延迟）与 **局域网 Wi-Fi** 无线直连。
  - **反向操控手机**：在电脑上用鼠标点击、滑动、拖拽、滚轮，键盘按键打字，完整反向操控手机。
  - **Android (Android 7+) 控制**：基于 USB / 无线 ADB 原生隧道直接注入触控与按键，免 Root，零延迟；支持无障碍服务。
  - **iOS (iOS 16+) 控制**：采用行业标准蓝牙 HID 模拟结合 iPhone“辅助触控（AssistiveTouch）”，免越狱实现鼠标操控。
- 🚀 **100% 纯云端 GitHub Actions 矩阵编译**：
  - 云端自动打包输出：`Android APK`、`iOS App`、`Windows x64 (.zip)`、`Windows ARM64 (.zip)`、`macOS Universal (.tar.gz)` 5 大产物。

详细系统架构与协议实现请参阅：[项目开发说明文档](docs/PROJECT_SPEC.md)
