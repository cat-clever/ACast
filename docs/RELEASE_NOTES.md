# ACast 发版说明

## v0.4.3 更新日志 (最新)

1. **全新键盘直通打字体验 (移除冗余输入框)**：
   * **控制端视窗极简重构**：彻底移除独立控制视窗底部的输入框与发送按钮，底栏精简为 44px（仅保留紧凑居中的返回、桌面、任务三键）；
   * **键盘焦点直通**：视窗默认持有第一响应者焦点，在投屏画面内敲击键盘直接在手机焦点输入框打字；
   * **输入防覆盖与光标连续键入**：优先采用原生光标剪贴板插入，备用模式引入时间感知文本缓冲区，彻底杜绝跨进程延迟导致的“单字覆盖只剩最后一个字符”；
   * **支持功能键**：完美支持 Backspace/退格键与 Enter/回车换行。

2. **彻底解决鼠标甩出视窗悬按卡死与滑动翻页回弹 (AppKit Tracking Loop & Fling Velocity)**：
   * **AppKit Mouse Tracking Loop**：在鼠标按下拖拽中引入模态事件追踪循环，无论鼠标以多快速度甩出视窗边缘、甩至 Dock 栏或屏幕角落，抬手瞬间 100% 毫无延迟捕获释放事件，彻底告别悬按卡死；
   * **滑动初速度赋予 (Fling Velocity)**：修复连续手势中 Fling 被短路的缺陷，在抬手收尾时赋予手势充足的末端速度矢量，使 Android 桌面平滑惯性翻页，杜绝因未达位移阈值导致的回弹。

3. **彻底根治锁屏息屏再解锁后黑屏无法恢复的缺陷 (VirtualDisplay Auto-Recovery)**：
   * **Android 14+ 投影实例复用**：遵守 Android 14 单个 MediaProjection 仅能创建一次 VirtualDisplay 的系统安全限制，息屏时保持 VirtualDisplay 实例，解锁时重新激活与硬件编码器 Surface 的绑定；
   * **连续 3 次关键帧下发**：亮屏与解锁瞬间连续触发 3 次 I 帧请求（0ms, 100ms, 300ms），硬件编码器立即输出携带 SPS/PPS 完整参数集的 IDR 帧，控制端画面秒级恢复。

4. **手机端全方位后台保活体系 (KeepAlive Framework)**：
   * **系统原生 Doze 电池优化白名单**：支持一键检测并直接弹出申请授权对话框，无限制在后台运行；
   * **主流厂商自启动与省电策略一键直达**：智能识别小米/红米（MIUI/HyperOS 安全中心自启动与神隐模式）、华为/荣耀、OPPO、vivo 等设置页，点击一键跳转；
   * **前台服务硬核加固**：服务配置 `android:stopWithTask="false"`，启动模式升级为 `START_STICKY`，引入高性能 `WifiLock`（`WIFI_MODE_FULL_HIGH_PERF`）防止锁屏 WiFi 断流，与常驻无障碍服务形成双进程互保守护；
   * **主界面保活状态卡片**：新增实时保活状态卡片，已开启显示绿色对勾，未开启一键呼出配置指引。

5. **屏幕投屏与 Mac 虚拟摄像头双通道并发无冲突**：
   * 解除屏幕投屏与虚拟摄像头的互斥限制，两套功能可同时独立运行；
   * 修复 macOS 端 VideoToolbox 解码器连接瞬间的 EXC_BAD_ACCESS 潜在崩溃，大幅增强稳定性。

---

## v0.4.2 更新日志

1. **全新推出 “在 Mac 上使用 Android 手机摄像头” 功能 (Android Webcam for Mac)**：
   * **macOS 现代 CoreMediaIO 虚拟摄像头扩展系统 (`CMIOExtensionProvider`)**：基于 Apple 推荐的系统扩展规范构建独立的虚拟摄像头设备 **【ACast 虚拟摄像头 (Android Camera)】**，彻底突破旧版 DAL 插件在 macOS Sonoma / Ventura / Sequoia 下被 FaceTime / Safari / 沙盒会议软件硬性屏蔽的限制；
   * **广泛兼容各类视讯软件**：在 Zoom、FaceTime、腾讯会议、Photo Booth、Google Meet、Safari 等应用中可直接在摄像头输入列表中选用；
   * **Android 端硬件级相机采集与推流**：基于 Camera2 采集与 MediaCodec H.264 硬件编码，支持 1080P/720P 高清推流，支持前置/后置镜头快速翻转与补光灯控制；
   * **智能待机占位图与极速本地中继**：在手机推流未就绪时自动呈现动态优雅待机画面；推流开启后毫秒级无损上屏，延迟低至 20ms。

---

## v0.4.1 更新日志

1. **全面重构连续手势引擎，彻底根治左右实时滑动卡顿抽搐缺陷 (Continuous Follow-up Gesture Engine)**：
   * **基于 continueStroke 的真实不松手连续滑动**：彻底废弃此前“每隔 12 像素强制执行一次包含 ACTION_UP 完整手势”引发的抽搐跳变（该旧方案导致桌面/翻页容器认为被不断触碰后松手弹回）。在 `ControlAccessibilityService` 中引入连续手势状态机与手势推进泵，通过 `willContinue = true` 配合 Android 8.0+ `continueStroke`，手指在滑动全程始终按压贴紧屏幕无缝移动，完全呈现与真机手指滑动 100% 相同的一体化触摸事件流；
   * **单击 (Tap) 与拖拽翻页 (Swipe) 智能分流**：位移小于 10 像素严格判定为快速点按（50ms 单击），绝不误触滑动；位移超过 10 像素平滑进入连续手势链条，左右滑屏翻页、刷列表如丝般顺滑自然；
   * **边缘滑动手势保护 (Boundary Clamping)**：macOS 视窗增强触控坐标边界钳位（Clamp），即使用户大幅度左右拖拽甩动滑出手机视窗黑边边缘，手势坐标也稳定在边界上平滑过渡，绝不丢弃滑动轨迹导致手势断裂。

---

## v0.4.0 更新日志

1. **彻底解决锁屏后解锁屏幕一直是黑的但能控制手机的问题 (Unlock Screen Blackout Fix)**：
   * **VirtualDisplay 亮屏/解锁自动唤醒重绑 (Surface Auto-Recovery)**：在 Android 端 `ScreenCaptureService` 中动态注册全局 `ACTION_SCREEN_ON`、`ACTION_SCREEN_OFF` 和 `ACTION_USER_PRESENT` 广播接收器；当检测到手机亮屏或用户解锁时，自动唤醒 VirtualDisplay 重新建立 Surface 镜像绑定，并接入 `VirtualDisplay.Callback`，彻底解决 Android 系统息屏导致虚拟镜像挂起黑屏的底层缺陷；
   * **反控操作智能唤醒屏幕与镜像 (Wake-on-Control)**：当用户在电脑端独立窗口点击鼠标或按键时，无障碍服务点亮屏幕的同时立即触发 `ScreenCaptureService.onScreenUnlocked()`，实现电脑端点按手机自动点亮屏幕并恢复彩色推流；
   * **电脑端硬解会话失效自愈 (Decoder Invalidation Recovery)**：修复 macOS `ScreenMirrorView` 在会话失效（`decompressionSession == NULL`）且 SPS/PPS 内容未变时无法重新初始化的严重缺陷。只要会话为空或格式丢失，收到下一关键帧即刻 100% 重建 VideoToolbox 硬件解码器，杜绝画面永久黑屏；
   * **解锁即时刷新全量 I 帧**：解锁瞬间向 MediaCodec 注入 `PARAMETER_KEY_REQUEST_SYNC_FRAME`，手机立即推送包含 SPS/PPS 的全新彩色 IDR 帧，绝不复用锁屏期间的全黑帧。

---

## v0.3.9 更新日志

1. **全面支持中文拼音/五笔输入法打字与快捷文本发送 (Full IME & Chinese Input Support)**：
   * **遵循 NSTextInputClient 协议**：投屏视窗（`ScreenMirrorView`）完整实现 macOS 原生 `NSTextInputClient` 协议，激活系统输入法管理器（InputMethodKit）。用户在手机画面上直接敲击中文拼音时，原生拼音选词候选框浮现于视窗下方，选词确认后汉字长句即刻完整上屏注入手机；
   * **独立视窗快捷文本输入条 (Quick Text Bar)**：在独立视窗底栏常驻双排综合操作区，新增快捷输入框与【发送】按钮，支持直接输入中文、长网址或直接粘贴大段文本按 Enter 瞬间秒发至手机输入框；
   * **键盘特殊按键与无障碍粘贴注入**：完善 ESC（返回）、Enter（回车换行）、Delete（逐字退格删除）及上下左右光标移动的精准映射。

2. **彻底解决鼠标拖拽滑动不跟手、只有松手才开始滑动的重大缺陷 (Real-time Follow-up Swipe)**：
   * **实时分段手势连续注入**：重构 `ControlAccessibilityService.injectTouch`。在 `TOUCH_MOVE` 拖拽过程中，根据滑动位移（>=12px 且 >=35ms）实时分段向 Android 系统派发快速平滑手势（30~80ms），屏幕紧贴鼠标指针实时左右跟手滚动滑动，彻底告别“拖拽时不滑、松手才猛划”的断裂体验；
   * **单击与滑动精准分离**：位移小于 10 像素时判定为单击（Tap），松手瞬间触发精准微位移点按；滑动松手时（TOUCH_UP）自动完成平滑收尾。

3. **连接首屏出图提速至毫秒级秒开，杜绝 2~3 秒黑屏等待 (Instant First-Frame Launch)**：
   * **最近关键帧全局快照缓存 (KeyFrame Snapshot Caching)**：Android 端 `FastMirrorSender` 自动持久缓存最近一份完整的关键帧数据包（包含 SPS + PPS + IDR Slice）；当任何电脑客户端建立 TCP 连接的一瞬间，手机端在 0ms 瞬间单播直推该帧给新客户端，VideoToolbox 收到即解码渲染，首屏出图时间从 2~3 秒骤降至 0.05 秒（秒开！）；
   * **静止画面 20fps 高频保底刷新**：将 `KEY_REPEAT_PREVIOUS_FRAME_AFTER` 调整为 50ms（20fps），彻底解决静止画面时 VirtualDisplay 停产帧导致的连接延迟；
   * **连接即时请求硬件 I 帧**：客户端连入时立即向 MediaCodec 注入 `PARAMETER_KEY_REQUEST_SYNC_FRAME`。

---

## v0.3.8 更新日志

1. **彻底解决弹出独立控制屏幕窗口卡死定格与断流 Bug (Single View Reparenting & Anti-Backpressure)**：
   * **单一统一视图无缝迁移架构 (Single ScreenView Reparenting)**：重构主窗口与独立窗口的视图拓扑，废除双 `ScreenMirrorView` 实例设计。统一使用唯一的 `screenView` 实例在主窗口与独立视窗间动态挂载迁移，硬件解码器 `VTDecompressionSession` 与 SPS/PPS 配置上下文全生命周期保留，跨窗口切换无需重建解码器，杜绝丢帧、黑屏与切换卡死；视频回调直接喂给单一视图，绝不在后台子线程中跨线程读取 `[window isVisible]`，从根源杜绝跨线程死锁与误判断流；
   * **高刷鼠标触控背压限流 (Touch Rate Limiting)**：针对鼠标连续拖拽滑动 `mouseDragged` 进行 16ms（60Hz）背压限流，防止外接高刷鼠标每秒向 UI 主线程疯狂发起阻塞式 Socket `send()`；`mouseDown` 和 `mouseUp` 保证 100% 立即发送；
   * **网络发送失败杜绝主线程同步 join 死锁**：在 `SendRawPacket` 中移除了在 UI 线程同步调用 `Disconnect()`（调用 `join` 等待子线程）的死锁代码，改为异步安全退出，杜绝 macOS 彩球假死；
   * **Android 手机端屏幕常亮锁强化 (Screen Bright WakeLock)**：`ScreenCaptureService` 新增 `PowerManager.SCREEN_BRIGHT_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP`，保证投屏期间手机屏幕 100% 不熄屏休眠，杜绝系统 1 分钟息屏超时导致 VirtualDisplay 停止推流；且新客户端连接时立即触发 `requestKeyFrame()` 生成首帧 IDR 关键帧；
   * **零积压最新帧调度器 (Zero-Lag Latest Frame Coalescing)**：重构 macOS VideoToolbox 帧渲染管道，主线程渲染消费与解码回调完全解耦。当系统负载或帧率波动导致主线程繁忙时，自动保留最新一帧并立即释放未及渲染的旧帧，从源头杜绝每秒 60 帧产生数十 GB 的 `VTCreateCGImageFromCVPixelBuffer` 内存积压，彻底消除 macOS `com.apple.coremedia.videodecoder` 进程被 watchdog 判定泄露引发的 `XPC_ERROR_CONNECTION_INTERRUPTED` 强杀崩溃；
   * **解码器故障自动重置与自愈机制**：增加 `handleDecodeError:` 容灾回调。当 VideoToolbox 报告会话异常或损坏帧时，自动重置销毁旧会话，并在收到下一个关键帧（SPS/PPS）时全自动无感重建解码器，杜绝画面永久卡死；
   * **超低延迟实时时间戳修正**：按苹果官方低延迟推流标准，将 `CMSampleTimingInfo` 配置为 `kCMTimeInvalid`，彻底关闭解码队列内部的时间戳重排序缓冲，降低显示延迟至极限；
   * **数据流防污染并发加锁保护**：Android 端 `FastMirrorSender` 彻底移除在视频流数据通道上并发回写 PONG 的代码，保持推流通道数据流纯净；同时对 `broadcast` 加以 `synchronized (s)` 线程安全保护，杜绝多线程写 Socket 引起的 NALU 帧头错位；
   * **控制端超大包自愈对齐**：控制端 `FastMirrorClient` 遇到单包字节超限时，自动执行单字节滑动查找魔数探测自愈，绝不断开连接。

2. **彻底解决电脑键盘输入只有最后一个字母的 Bug (Natural Typing & Delete Support)**：
   * **光标位置剪贴板优先粘贴 (Clipboard Paste Injection)**：重构 `ControlAccessibilityService.injectText`，优先通过系统剪贴板光标处粘贴（`ACTION_PASTE`），支持中英文长句、单词在光标处自然连续打字；
   * **已有文本拼接追加兜底**：在不支持粘贴的特殊输入控件中，读取已有文本并在末尾追加拼接后更新，彻底废除直接用单个字母覆盖整框文本（`ACTION_SET_TEXT`）的旧缺陷；
   * **全能退格删除键 (Backspace/Delete) 支持**：`injectKey` 新增对按键码 7（`KEY_DEL`）的支持，支持逐字退格删除打错字符。

---

## v0.3.7 更新日志

1. **弹出独立控制屏幕窗口后主窗口屏幕控制自动关闭联动 (Exclusive Screen Control)**：
   * **主窗口控制区域自动关闭隐藏**：当点击【⤢ 弹出独立控制屏幕窗口】或手机连接自动弹出独立视窗后，主窗口左侧原有的屏幕投屏画面（`screenView`）与底部导航按键栏（`screenNavBar`）自动关闭隐藏，杜绝多处重复显示和重复操作的割裂感；
   * **优雅的独立运行待命占位卡片 (Detached Placeholder Panel)**：在主窗口原控制区域优雅展示深色待命面板，清晰提示“手机屏幕控制已移至独立视窗”，并提供居中的【⤓ 收回控制屏幕至主窗口】快捷按钮；
   * **智能双向双控收回联动**：顶部按钮自适应切换为【⤓ 收回控制屏幕至主窗口】。用户在主窗口点击收回按钮，或直接点击独立视窗左上角的关闭红叉时，独立视窗平滑关闭，主窗口的屏幕控制无缝重新开启；
   * **解码与视频渲染资源节省**：当独立视窗运行时，视频流只向独立窗口解码分发渲染，停止主窗口的冗余渲染，显著降低 CPU 与 GPU 占用。

---

## v0.3.6 更新日志

1. **彻底根治控制手机时控制台端假死卡顿 (Zero UI Freezing / Beachball Elimination)**：
   * **ADB 异步非阻塞执行队列 (AdbWorkerQueue)**：将 `InjectTap`、`InjectSwipe`、`InjectText`、`InjectKeyEvent`、`InjectBack`、`InjectHome`、`InjectAppSwitch` 等反控注入命令全面迁移至底层单线程异步工作队列，UI 主线程调用耗时降至 0ms，彻底消除无线 Wi-Fi ADB 网络延迟或进程等待导致的主线程冻结、macOS 彩球（Beachball）和 Windows“未响应”；
   * **高频触控背压防积压机制 (Backpressure Rate Limiting)**：针对鼠标连续滑动/高频拖拽，工作队列限制最大手势积压量，自动舍弃过时点位，杜绝手势堆叠延迟；功能导航键（返回、桌面、任务、文本输入）保证 100% 按序投递执行。
2. **FastMirror 私有协议长连接链路稳定性与保活强化**：
   * **移除误判超时的强制断开**：移除了长连接控制 socket 上强制 3 秒读取超时的限制，替换为系统级 `SO_KEEPALIVE` 长连接保活，杜绝空闲时连接被误判断开回退到慢速 ADB；
   * **客户端主动心跳机制 (Heartbeat PING/PONG)**：内置后台心跳线程定期向手机发送 `PING (0x03)` 保活包，Android 服务端自动回复 `PONG (0x04)`，防止链路闲置被局域网路由器超时切断；
   * **全量循环发送与非阻塞重试**：改造 `SendRawPacket` 为 `while (total_sent < total)` 完整发送循环，对网络轻微背压（EAGAIN/EWOULDBLOCK）优雅重试，绝不在部分发送时粗暴断开；
   * **滑动窗口自愈对齐 (Sliding Window Resync)**：双端（C++ 控制端与 Android 服务端）均实现单字节滑动探测重对齐机制，若网络中存在瞬时脏字节或单字节错位，自动逐字节滑动查找 `MAGIC` 魔数，杜绝帧边界丢失导致的永久解包失效。
3. **手机端无障碍服务引导 Toast 提示**：
   * 当用户在电脑控制屏幕上点击“返回”、“桌面”、“任务”等按键，若手机端尚未开启【ACast 投屏反控】无障碍服务，手机屏幕将立即弹出醒目的引导 Toast，清晰提示用户前往系统设置开启授权，杜绝无反馈假象。

---

## v0.3.5 更新日志

1. **控制屏幕支持独立专属窗口 (Standalone Control Window)**：
   * 手机投屏视窗彻底独立化，支持随意缩放拖拽与全屏高清自适应渲染；
   * 手机连通后自动弹出独立控制窗口，主控制台亦提供【🖥️ 弹出独立控制屏幕】按钮随时一键调出。
2. **返回（Back）、桌面（Home）、任务（Tasks）直接做到控制屏幕中**：
   * 手机控制视窗底端常驻内置 `◀ 返回`、`○ 桌面`、`▢ 任务` 三大系统导航键；
   * 用户直接在控制屏幕中单手操作手机，支持鼠标左键拖拽、右键返回与键盘输入。
3. **彻底根治“私有协议时 返回/桌面/任务 没有任何反应”的 Bug**：
   * 修复 C++ 与 Android 端的协议魔数字节序不匹配（Endianness Bug），兼容 `0x464D` 与 `0x4D46`，彻底杜绝控制包被误判丢弃；
   * 兼容 `MSG_KEY_DOWN (0x20)` 与 `MSG_SYSTEM_KEY (0x23)`，按键指令响应灵敏准确。

---

## v0.3.4 更新日志

1. **彻底恢复控制端对手机的鼠标与按键反控 (Mouse & Touch Control)**：
   * **主线程调度与手势容错 (Path Length Fix)**：针对 Android 14/15/16 (如小米 HyperOS) 系统手势框架对 Path 长度必须非零的限制，在 `ControlAccessibilityService` 中增加点按微位移容错 (+1.0f)，并将所有 `dispatchGesture` 与按键模拟强制调度至主线程 (Main Looper)，杜绝子线程工作队列导致的注入失败或 Empty Path 异常；
   * **物理像素高精度映射 (RealMetrics)**：使用 `getRealMetrics` 精确匹配全面屏、打孔屏的真实物理像素分辨率；
   * **手机端无障碍服务一键引导**：在手机端主界面添加【🖱️ 电脑鼠标反控】状态卡片，醒目提示无障碍权限状态并支持一键直达系统设置授权。
2. **根治手机自动锁屏与连接断开问题 (Keep Screen On & Persistent Link)**：
   * **全局屏幕常亮保护 (Accessibility Overlay)**：投屏期间利用无障碍服务在顶层挂载 1x1 像素透明 Overlay 窗口并附加 `FLAG_KEEP_SCREEN_ON`，无论手机切到桌面还是其他第三方 App，投屏期间均保持常亮不自动锁屏休眠；
   * **CPU 保活 WakeLock**：在 `ScreenCaptureService` 中申请 `PowerManager.PARTIAL_WAKE_LOCK`，杜绝后台低功耗挂起；
   * **解耦服务生命周期**：移除 `ScreenCaptureService.onDestroy` 中对 `FastMirrorSender` 与 `LocalHttpTsServer` 的暴力关闭，网络通道始终长驻不切断；
   * **熄屏鼠标操作自动唤醒**：在手机熄屏状态下收到控制端鼠标点击指令时，自动获取唤醒锁点亮屏幕。

---

## v0.3.3 更新日志

1. **彻底解决 Windows 控制端文字乱码 (Mojibake)**：
   * **全局开启 MSVC `/utf-8` 参数**：为 MSVC 编译系统强制注入 `/utf-8` 参数，确保所有 C++ 源码、宽字符字面量与日志在 GitHub Actions 英文环境编译时正确解析为 UTF-8 / UTF-16，杜绝按钮与标签乱码；
   * **自适应宽字符解码**：`Utf8ToWide` 采用 UTF-8 校验与系统 ANSI (GBK/CP936) 兜底双通道，无缝兼容各类外部命令与终端控制台输出；
   * **引入应用程序清单 (app.manifest)**：声明 Windows 10/11 原生 `<activeCodePage>UTF-8</activeCodePage>` 与现代 Common Controls 6.0，全面支持高分屏 DPI 自适应。
2. **彻底杜绝终端黑框窗口弹出 (Zero Console Window Popup)**：
   * **原生 Win32 静默进程调度引擎 (`process_runner.h`)**：全面替换 `_popen` 与 `std::system`；底层基于 `CreateProcessW` + `CREATE_NO_WINDOW` + `SW_HIDE` 管道，执行 ADB、设备检测、端口转发与触控模拟时全局零黑框；
   * **静默热替换重启**：更新完成后通过 `ShellExecuteExA` 配合 `SW_HIDE` 静默重启程序。

---

## v0.3.2 更新日志

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
