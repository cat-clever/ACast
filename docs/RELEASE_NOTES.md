# ACast 发版说明

## v0.2.0 更新日志 (最新)

1. **桌面控制端全面升级为纯原生图形界面 (GUI)**：
   * **macOS 原生 Cocoa (AppKit) 视窗**：采用纯 Objective-C++ 与 Cocoa AppKit 编写，GPU 硬件加速渲染，彻底移除终端与 AppleScript 弹窗，双击即开，沉浸式深色/浅色自适应风格；
   * **Windows 原生 Win32 视窗**：采用 Win32 API 与 Common Controls v6 现代视觉样式，配置 `/SUBSYSTEM:WINDOWS`，无黑框控制台，毫秒级冷启；
   * **全功能控制视窗**：集成版本状态展示与一键在线热更新、USB 手机反控卡片（状态识别、返回键/桌面键控制）、局域网大屏设备发现与管理列表、内置沉浸式运行日志控制台。
2. **彻底解决 macOS 启动 SIGABRT 崩溃 (`std::__throw_regex_error<11>`)**：
   * 修复 `core/src/dlna_controller.cpp` 中非标准 `(?i)` 正则内嵌标志引起的 `libc++` 异常崩溃，规范为 `std::regex_constants::icase`；
   * 为 SSDP 组播发现与 XML 端点解析添加全局异常捕获保护网，彻底杜绝闪退。

---

## v0.1.9 更新日志

1. **彻底解决 AirPlay 协议大屏无法投屏及 404 (playlist not found) 问题**：
   * 修复协议分流错误：解决此前误将 DLNA SOAP XML 发送至 AirPlay 7001 端口导致 404 的致命缺陷；
   * 全面实现标准 AirPlay `POST /play` 控制协议，携带会话标识与 `Content-Location` 参数；
   * 增加 7000 与 7001 双端口自动容灾轮询，增加 text/parameters 与 Apple XML Plist 自动回退机制。

---

## v0.1.8 更新日志

1. **彻底解决电视投屏一直显示“在缓冲”及拉流失败 (Operation Stopped) 的重大问题**：
   * 纯 Java 实现完整的 MPEG-2 TS 实时封装引擎，补全流媒体 Socket 推流管道；
   * 自动捕获与组装 SPS/PPS 编码配置，在关键帧中注入 PCR (Program Clock Reference) 硬件时钟基准；
   * 引入 GOP 环形缓存首屏秒开机制（Burst Cache），电视接入瞬间爆发推送关键帧数据，实现毫秒级快速出图；
   * DLNA SetAVTransportURI 注入标准 DIDL-Lite 描述，显式声明 `protocolInfo="http-get:*:video/mp2t:*"` 消除大屏探测耗时。

---

## v0.1.7 更新日志

1. **优化投屏时序，改为先开启投屏然后再点击投屏设备**：
   * 业务拦截保护：在未开启屏幕投屏时点击设备列表，自动拦截阻断并提醒“⚠️ 请先开启屏幕投屏！”，杜绝因本地流服务未启动导致电视拉流失败黑屏；
   * 智能自动流转：拦截后自动记忆目标大屏，并主动拉起录屏授权弹窗，授权成功后无需用户再次点击即可自动向该大屏发起投屏；
   * UI 流程步骤化：界面明确划分为“1. 开启屏幕投屏”、“2. 搜索大屏设备”、“3. 点击大屏设备开始投屏”，根据投屏状态实时变色提示。

---

## v0.1.6 更新日志

1. **集成项目持久统一签名，彻底解决 Android APK 签名不一致问题**：
   * 将统一的 Release 签名密钥文件 `acast-release.jks`（有效至 2054 年）固化到项目中；
   * 在 `build.gradle` 中统一配置并强制绑定到 `release` 与 `debug` 模式；
   * 全面启用 V1 (Jar Signature) 与 V2 (Full APK Signature) 签名方案；
   * 彻底杜绝因云端构建临时密钥不同导致的覆盖安装失败（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），完美保障应用内热更新覆盖体验。

---

## v0.1.5 更新日志

1. **彻底解决 macOS 双击应用图标没有任何反应的问题**：
   * 增加终端运行环境嗅探，当由 Finder / 访达双击打开时，自动激活并弹起 macOS 原生 Terminal.app 独立控制台窗口；
   * 打包流程显式加入 `chmod -R 755` 与可执行文件 `+x` 权限校验，保证拖拽至 `/Applications` 即开即用；
   * 补全 `Info.plist` 标准描述信息与权限声明。

---

## v0.1.4 更新日志

1. **彻底攻克局域网投屏搜索不到大屏设备的技术顽疾**：
   * 配置 `android:usesCleartextTraffic="true"`，解除 Android 9~14 底层网络安全策略对局域网明文 HTTP 设备描述的拦截；
   * 扩展 SSDP 为多目标复合探测（`upnp:rootdevice`, `MediaRenderer`, `AVTransport`, `ssdp:all`），多频次重发防丢包；
   * 集成 Android 原生 `NsdManager` 服务发现，同步搜索 AirPlay（`_airplay._tcp.`）和 Cast（`_googlecast._tcp.`）大屏设备；
   * 重构容错 XML 解析引擎，彻底解决不同品牌电视标签顺序不一致导致的解析丢弃问题；
   * 点击列表项真正调起向大屏的推流播放指令。

---

## v0.1.3 更新日志

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
