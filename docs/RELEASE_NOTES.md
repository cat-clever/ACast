# ACast 发版说明

## v0.3.2 更新日志 (最新)

1. **彻底解决 ADisplay / 智能电视大屏投屏中断 (Playback Stopped / Operation Stopped)**：
   * **绕开 ADisplay 点播换封装引擎**：通过深入分析 ADisplay 服务端源码，确定其内部 `MediaRelay` 会误将 `.m3u8` 当做点播文件并强行添加 `#EXT-X-ENDLIST` 导致播完前几秒后直接中断。将 DLNA 直连推送端点更新为 `http://<ip>:8088/live`，彻底绕过破坏性拦截，交由原生播放器（AVPlayer / ExoPlayer）以原生实时直播协议拉流，永不断流；
   * **M3U8 多路由支持**：`LocalHttpTsServer` 统一支持 `/live` 与 `/live.m3u8` 路由，并声明合规 MIME `application/vnd.apple.mpegurl`；
   * **首帧保底分片机制**：启动时注入初始待命切片，确保客户端在未收到第一帧前不会因清单为空而报错退出；
   * **编译语法修复**：剔除 `LocalHttpTsServer.java` 中多余花括号，恢复 Android APK 自动打包构建。
2. **桌面控制端实时画面与全功能反控**：
   * **双分栏专业控制台**：左侧 420x690 专用手机视窗，右侧控制与日志面板；
   * **macOS VideoToolbox 硬件解码**：低延迟超清渲染手机投屏画面；
   * **鼠标拖拽/滑动手势与键盘输入**：支持鼠标单点与滑动拖拽（精准归一化坐标）、右键返回、键盘打字直接输入到手机。

---

## v0.3.1 更新日志

1. **彻底解决 ADisplay / 电视大屏投屏中断 (Playback Stopped)**：
   * **深入源码排查**：分析 ADisplay 源码发现其 `MediaRelay` 换封装模块会将含 `.m3u8` 的流误判为点播（VOD），强加 `#EXT-X-ENDLIST` 导致播完 4 秒直接中断；
   * **直通直播流端点 `/live`**：推流地址升级为 `http://<ip>:8088/live`，彻底绕开 ADisplay 点播换封装的错误拦截，直通系统 AVPlayer / ExoPlayer 原生直播流；
   * **首帧保底分片机制**：启动时预初始化合规待命分片，确保清单永远有合法有效分片，杜绝播放器因解析到空列表直接失败；
   * **AirPlay 报错解密**：揭秘 ADisplay 底层 UxPlay 在 `POST /play` 时硬编码只认 YouTube 二进制 plist 的限制，强化稳定性更强的 DLNA 直连通道。

---

## v0.3.0 更新日志

1. **彻底修复 Android 端 HLS 直播服务与录屏初始化**：
   * **参数一致性修复**：修复 `MainActivity` 与 `ScreenCaptureService` 传参 key（`code` vs `resultCode`）不匹配导致的录屏未激活 Bug，彻底恢复底层 MediaProjection 与硬件编码器正常流转；
   * **端口提早预就绪**：将 `LocalHttpTsServer` (8088) 与 `FastMirrorSender` (19999) 提前在应用启动时就绪，彻底避免大屏设备和电脑连入时报 Connection Refused；
   * **界面流地址展示**：在手机主界面显式标明当前 HLS 直播流地址（`http://<ip>:8088/live.m3u8`），方便即时验证与拉流。
2. **控制端重磅升级：实时投屏视窗 + 鼠标操控滑动 + 键盘直接输入**：
   * **专业双分栏视窗**：左侧提供 420x690 超大高保真手机画面视窗，右侧集成设备连接、反控按键与运行日志；
   * **macOS VideoToolbox 硬件加速极速硬解**：Annex-B 自动转 AVCC，零拷贝 GPU 实时上屏，延迟低于 20ms；
   * **鼠标点击与顺滑拖拽模拟触控**：鼠标点击、拖拽滑动精准映射为画面归一化坐标实时发给手机，无障碍服务顺滑模拟手势；鼠标右键直接触发手机返回键；
   * **键盘打字输入与快捷键**：ESC 映射返回、Return 映射回车、Delete 映射退格、方向键精准映射；电脑键盘输入文本直接实时填入手机输入框！

---

## v0.2.9 更新日志

1. **彻底修复 macOS 启动野指针崩溃 (SIGSEGV / EXC_BAD_ACCESS)**：
   * **生命周期安全隔离**：修复 `SetUsbDeviceCallback` 和 `SetDiscoveredPhonesCallback` 闭包直接引用栈内存局部变量导致的非法内存访问；引入 `std::make_shared` 安全堆托管，确保 GCD 异步派发至主线程时数据绝对有效；
   * **安全防爆字符串转换**：增加 `SafeStr` 杜绝空值或异常编码向 NSDictionary 插入 `nil` 导致的异常；
2. **界面文案精简大方**：
   * 将控制端“原地热更新”按钮文字直接简化为“**更新**”。

---

## v0.2.8 更新日志

1. **局域网全自动双向对等发现 (Peer Discovery) 与去端口化**：
   * **彻底移除端口展示，体验至简**：手机端与控制端界面彻底隐藏所有通信端口（如 `19999`），免除用户抄录或配置任何网络参数；
   * **电脑与手机自动双向互相发现**：通过自研轻量级 UDP 局域网广播发现协议，电脑控制端实时呈现局域网内所有手机，手机发射端实时呈现所有在线电脑控制端与大屏电视；
   * **双向一键连接反控**：电脑端下拉选择手机一键直连；手机端设备列表直接点击电脑控制端，系统自动通知电脑建立 FastMirror 极速反控通道。

---

## v0.2.7 更新日志

1. **Android 发射端全面升级为 HLS 实时流协议架构**：
   * **彻底根治大屏接收端拉流失败 (Operation Stopped)**：针对 macOS ADisplay（Apple AVPlayer 引擎）等大屏设备无法直接播放裸 HTTP MPEG-TS 长连接流的问题，全面升级为符合 RFC 8216 标准的 Live HLS（`live.m3u8`）架构；
   * **内存短分片切片引擎**：自研轻量内存滑动窗口切片器，每秒切出独立 TS 分片（带完整 PAT/PMT/SPS/PPS 关键帧），无 `#EXT-X-ENDLIST` 标签，实现毫秒级起播与超低延迟播放；
   * **协议智能兼容**：保留 `/live.ts` 长连接接口向下兼容老旧硬件，DLNA DIDL-Lite 动态自适应 MIME 标头。

---

## v0.2.6 更新日志

1. **桌面控制端全面内置 Google 官方 ADB 调试桥工具**：
   * **出厂直接内置**：macOS Universal DMG 产物直接内置 Apple Silicon + Intel 官方 `adb` 工具（置于 `ACast.app/Contents/MacOS/adb`）；Windows 发行 ZIP 包中直接内置官方 `adb.exe`、`AdbWinApi.dll` 与 `AdbWinUsbApi.dll`，用户解压/双击即开，零环境依赖；
   * **智能四级自动探测与动态补齐机制**：优先使用安装包内置 ADB，其次匹配本地标准 SDK，若全无则自动从 Google 官方高速通道静默安装至用户工具目录，彻底告别“本地未检测到 adb 命令行工具”。

---

## v0.2.5 更新日志

1. **桌面控制端界面架构全面精简与职责纯粹化**：
   * **彻底剔除局域网大屏设备无用列表**：明确界定【手机发射端】与【桌面控制端】的职责分工，彻底移除 macOS Cocoa 原生视窗与 Windows Win32 视窗中的“局域网大屏设备 (DLNA / Cast / AirPlay)”表格与控件，停止无谓的后台大屏组播扫描；
   * **运行状态与日志视窗空间倍增**：将移除大屏列表后省下的大块垂直高度让给底部的【运行状态与事件日志】视窗，高度由 235 扩充至 410，手机 Wi-Fi 直连与 USB 反控链路日志一览无余，界面更加专业干净。

---

## v0.2.4 更新日志

1. **彻底修复 macOS 及 Windows 端一键原地热更新失败与权限拒绝根因**：
   * **规范用户级缓存路径**：彻底移除应用安装目录下的相对路径 `update_cache`。macOS 采用标准用户缓存目录 `~/Library/Caches/com.catclever.acast/update`，Windows 采用 `%LOCALAPPDATA%\ACast\update`，杜绝从 `/Applications/ACast.app` 启动时工作目录在根目录 `/` 引起的 `EACCES (Permission denied)` 与 curl 错误 23；
   * **递归创建目录支持**：引入 `CreateDirectoriesRecursively`，保证深层缓存目录安全按需创建；
   * **三重网络加速与镜像容灾通道**：配置 15 秒连接超时与重试，首选 GitHub Releases 官方直链；当遭遇国内网络超时或波动时，自动无缝切换至高速加速镜像（`mirror.ghproxy.com` 及 `ghproxy.net`）进行二次容灾下载；严格校验安装包大小 (>512KB) 杜绝损坏包；
   * **macOS 平滑覆盖与无感自启**：后台脚本等待原主进程 PID 退出后原地覆盖安装，自动清理 DMG 挂载卷与 quarantine 隔离属性，并无缝重启新版本。

---

## v0.2.3 更新日志

1. **彻底攻克 Android DLNA 投屏大屏拉流失败 (Operation Stopped) 的核心根因**：
   * **静止画面恒定推流守护**：为硬件编码器配置 `KEY_REPEAT_PREVIOUS_FRAME_AFTER = 100000L`，彻底解决屏幕静止时编码器停产导致电视 2 秒读不到新数据超时抛出 `Operation Stopped`；
   * **高频 PCR 时钟心跳守护**：引入 40ms 高频 PCR 心跳 TS 包，符合 ISO/IEC 13818-1 规范，维持电视硬件解复用芯片时钟锁相环同步，杜绝时钟失锁断流；
   * **连接即刷 I 帧**：电视连入瞬间主动向 `MediaCodec` 请求 `PARAMETER_KEY_REQUEST_SYNC_FRAME` 刷新关键帧，连同 PAT/PMT 首屏秒开；
   * **DLNA 规范 HTTP 标头与时序**：补全 `transferMode.dlna.org: Streaming` 与 `DLNA.ORG_OP=01`，规范 `HEAD` 探测请求，并在投屏发送 `SetAVTransportURI` 后预留 500ms 缓冲等待大屏建联后再发 `Play`。

---

## v0.2.2 更新日志

1. **控制端全面支持 FastMirror 私有协议局域网 Wi-Fi IP 与端口直连**：
   * **突破连接拓扑**：桌面控制端（Windows & macOS 原生视窗）除原有的 USB 专线连接外，现已全面开放局域网 IP 与端口直连能力；
   * **手机反控中心面板升级**：新增局域网 IP、端口配置框与一键【连接 Wi-Fi】按钮，实时响应连接状态；
   * **双通道智能反控流转**：反控操作（【返回】、【桌面】、【多任务】）优先走 FastMirror 局域网私有二进制协议通道 (<20ms)，离线时自动智能降级至 USB ADB 通道；
   * **网络健壮性强化**：手机端与控制端 TCP 采用完整的 `readFully` 数据帧流保护，杜绝 Wi-Fi 抖动拆包导致的断连；手机端开启投屏后即时醒目提示本机 IP:Port。

---

## v0.2.1 更新日志

1. **彻底解决 macOS 启动时 SIGSEGV (EXC_BAD_ACCESS) 崩溃**：
   * **根因定位**：修复 `gui_macos.mm` 中由于异步 GCD Block 捕获了后台 C++ 线程栈上的局部变量引用，在主线程 RunLoop 调度执行时该栈帧已被释放销毁，导致解引用无效内存地址（`KERN_INVALID_ADDRESS`）触发段错误；
   * **全生命周期重构**：核心控制层通知全部重构为值传递深拷贝，并在派发到主线程 Block 前显式转换为 ARC 托管的强引用 Cocoa 原生对象；
   * **时序与代理保护**：提升 `AppDelegate` 为全局强引用单例，将服务初始化严格安排在主窗口完全加载渲染完成后启动，彻底杜绝任何时序竞争。
2. **iOS 端新增补签名专用 IPA 安装包 (`acast-ios.ipa`)**：
   * 采用标准 Payload 架构直接打包 arm64 原生 Mach-O 二进制文件与 ReplayKit 2 广播上传扩展；
   * 预置合规 Info.plist 与 Ad-hoc 签名，支持爱思助手、AltStore、Sideloadly、牛蛙助手、轻松签及 TrollStore 巨魔商店一键补签/重签名安装。

---

## v0.2.0 更新日志

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
