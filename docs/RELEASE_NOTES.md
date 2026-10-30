# ACast 发版说明

## v0.1.3 更新日志 (最新)

1. **彻底修复 Android 点击“开启屏幕投屏”闪退自动退出的问题**：
   * 修复 Android 14 (API 34) 前台服务类型与 `MediaProjection.Callback` 注册要求；
   * 修复硬件 H.264 编码器在特殊比例屏幕下的配置崩溃，加入自适应分辨率缩放与 720P 安全重试；
   * 增加运行时权限检查与静音容错保护；
   * 注册全局未捕获异常守护器，杜绝静默闪退。
2. **全面规范投屏协议名称**：
   * 全面剔除所有“B站协议”字样，规范统一显示为：**DLNA / Cast / AirPlay**。

---

## v0.1.2 更新日志

1. **全新内置直接在线热更新体系 (In-App Auto-Update)**：
   * **macOS**：静默下载 DMG 并在后台静默挂载，原地无感替换 `/Applications/ACast.app` 并重启，彻底免除手动双击 DMG 与拖拽操作；
   * **Windows**：静默拉取并解压 ZIP，后台守护批处理突破文件句柄锁定完成 `.exe` 热替换自启，无需手动解压覆盖；
   * **Android**：应用内集成 `AutoUpdater`，下载后通过 `FileProvider` 调起原生 PackageInstaller 快速覆盖升级。
2. **桌面端交互更新命令**：
   * 启动时后台异步检测最新版本；
   * 支持控制台输入 `update` 指令触发全自动原地直接更新；输入 `check` 检查更新状态。

---

## v0.1.1 更新日志

1. **统一各端高分辨率软件图标**：
   * 视觉规范：现代圆角渐变背景 + 大屏电视投屏外框 + 无线声波 + 移动手机端 Cast 图标。
   * macOS：原生 1024x1024 多尺寸标准 `acast.icns`。
   * Windows：原生高分辨率多尺寸 `acast.ico`（嵌入 `.exe` PE 资源区）。
   * Android：全套 `mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}` 启动图标。
   * iOS：标准 1024x1024 `AppIcon.png`。
2. **优化 macOS DMG 安装体验**：
   * 移除 DMG 内冗余的 `README`。
   * DMG 镜像根目录下集成指向 `/Applications` 的软链接快捷方式，支持一步拖拽快速安装。
   * 写入标准的 `Info.plist` 与应用图标关联。

### 各平台安装包清单 (v0.1.1)

| 文件名 | 适用平台与架构 | 直接下载链接 | 说明 |
| :--- | :--- | :--- | :--- |
| `acast-macos-universal.dmg` | macOS 12+ (Apple Silicon M1~M4 & Intel Mac) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.1/acast-macos-universal.dmg) | Universal 2 架构，含 `/Applications` 拖拽安装快捷方式与统一应用图标 |
| `acast-windows-x64.zip` | Windows 10/11 (Intel / AMD 64位) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.1/acast-windows-x64.zip) | 解压即用，已内嵌原生 `acast.ico` 软件图标 |
| `acast-windows-arm64.zip` | Windows 11 on ARM (骁龙 X Elite / Surface ARM) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.1/acast-windows-arm64.zip) | 原生 ARM64 指令集，已内嵌原生 `acast.ico` 软件图标 |
| `acast-android.apk` | Android 7.0 及以上手机 (通用 APK) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.1/acast-android.apk) | 手机安装，已配置原生启动图标 |
| `acast-ios.zip` | iPhone (iOS 16.0 及以上) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.1/acast-ios.zip) | 包含 ReplayKit 2 广播上传扩展与应用图标 |

---

# ACast v0.1.0 发版说明

跨平台主动投屏与反向控制客户端（支持 DLNA / Cast / AirPlay 大屏投屏 & Windows/macOS 极低延迟 USB/Wi-Fi 音画反控）。

## 核心特性与支持范围

### 1. 电视大屏免装软件投屏（DLNA / Cast / AirPlay 协议体系）
*   **免装软件协议覆盖**：原生支持 DLNA、Cast 与 AirPlay 标准协议，局域网内任意智能电视、电视盒子（小米、华为、海信、创维、天猫魔盒等）**无需安装任何接收端软件**，即搜即投。
*   **双模式支持**：
    *   **手机实时屏幕镜像**：通过本地微内核 HTTP-TS 实时流，将手机屏幕与声音以极低延迟（80~150ms）推送到电视全屏播放；
    *   **在线/本地流媒体投送**：直接将视频流 URL 投送给电视原生播放器，手机可息屏，支持暂停与进度调节。

### 2. 桌面端极低延迟 & 鼠标键盘反向操控手机（自研 FastMirror 协议体系）
*   **Windows (x86_64 与 ARM64 双架构)** & **macOS (Universal 2: Apple Silicon + Intel)** 原生支持。
*   **USB 数据线直连**：极高带宽、零无线干扰、端到端时延 **15~35ms**，即插即用。
*   **局域网 Wi-Fi 直连**：同一局域网自动发现，时延 30~50ms。
*   **反向操控手机**：在电脑窗口中使用鼠标点击、滑动、拖拽、滚轮，键盘按键打字，完整反向控制手机。
    *   Android 7+：基于 USB / 无线 ADB 原生隧道直接注入事件，免 Root，零延迟；同时支持系统无障碍服务模式。
    *   iOS 16+：支持标准蓝牙 HID 模拟与 iPhone 辅助触控（AssistiveTouch）。

### 3. 音频捕获全版本适配
*   **Android 10+**：启用官方 `AudioPlaybackCapture` 进行免 Root 纯净系统音频捕获。
*   **Android 7~9**：启用麦克风外录降级兼容，保证低版本免 Root 正常出声。
*   **iOS 16+**：采用 ReplayKit 2 广播扩展捕获系统音频样本。

---

## 各平台安装包清单 (v0.1.0)

| 文件名 | 适用平台与架构 | 直接下载链接 | 说明 |
| :--- | :--- | :--- | :--- |
| `acast-windows-x64.zip` | Windows 10/11 (Intel / AMD 64位) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.0/acast-windows-x64.zip) | 解压即用，插 USB 数据线即可反控 Android 手机 |
| `acast-windows-arm64.zip` | Windows 11 on ARM (骁龙 X Elite / Surface ARM) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.0/acast-windows-arm64.zip) | 原生 ARM64 指令集，无模拟损耗 |
| `acast-macos-universal.dmg` | macOS 12+ (Apple Silicon M1~M4 & Intel Mac) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.0/acast-macos-universal.dmg) | Universal 2 统一架构安装包 |
| `acast-android.apk` | Android 7.0 及以上手机 (通用 APK) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.0/acast-android.apk) | 手机安装，开启屏幕投屏与电视搜索 |
| `acast-ios.zip` | iPhone (iOS 16.0 及以上) | [⬇️ 下载](https://github.com/cat-clever/ACast/releases/download/v0.1.0/acast-ios.zip) | 包含 ReplayKit 2 广播上传扩展 |
