#if defined(__APPLE__)

#import <Cocoa/Cocoa.h>
#include "gui_interface.h"
#include "desktop_controller.h"
#include "auto_updater.h"
#include <vector>
#include <string>

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    NSWindow* window;
    NSTextView* logTextView;
    NSTextField* updateBannerLabel;
    NSButton* updateButton;
    NSTextField* wifiStatusLabel;
    NSTextField* ipTextField;
    NSTextField* portTextField;
    NSButton* connectWifiBtn;
    NSTextField* usbStatusLabel;
    NSProgressIndicator* updateProgressIndicator;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSRect frame = NSMakeRect(0, 0, 780, 690);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:style
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setTitle:@"ACast 跨平台投屏控制台"];
    [window setMinSize:NSMakeSize(680, 560)];
    [window center];

    NSView* contentView = [window contentView];

    // ==================== 1. 顶部 Header ====================
    NSTextField* titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 645, 300, 30)];
    [titleLabel setStringValue:@"ACast 跨平台投屏控制端"];
    [titleLabel setFont:[NSFont systemFontOfSize:17 weight:NSFontWeightBold]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [contentView addSubview:titleLabel];

    NSTextField* versionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(280, 647, 120, 24)];
    std::string verStr = std::string("v") + acast::updater::AutoUpdater::CURRENT_VERSION;
    [versionLabel setStringValue:[NSString stringWithUTF8String:verStr.c_str()]];
    [versionLabel setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
    [versionLabel setTextColor:[NSColor secondaryLabelColor]];
    [versionLabel setBezeled:NO];
    [versionLabel setDrawsBackground:NO];
    [versionLabel setEditable:NO];
    [versionLabel setSelectable:NO];
    [contentView addSubview:versionLabel];

    NSButton* checkUpdateBtn = [[NSButton alloc] initWithFrame:NSMakeRect(640, 645, 115, 30)];
    [checkUpdateBtn setTitle:@"检查更新"];
    [checkUpdateBtn setBezelStyle:NSBezelStyleRounded];
    [checkUpdateBtn setTarget:self];
    [checkUpdateBtn setAction:@selector(onCheckUpdateClicked:)];
    [contentView addSubview:checkUpdateBtn];

    // ==================== 2. 更新横幅 (默认隐藏) ====================
    updateBannerLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 612, 580, 24)];
    [updateBannerLabel setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    [updateBannerLabel setTextColor:[NSColor systemGreenColor]];
    [updateBannerLabel setBezeled:NO];
    [updateBannerLabel setDrawsBackground:NO];
    [updateBannerLabel setEditable:NO];
    [updateBannerLabel setHidden:YES];
    [contentView addSubview:updateBannerLabel];

    updateButton = [[NSButton alloc] initWithFrame:NSMakeRect(620, 610, 135, 28)];
    [updateButton setTitle:@"原地热更新"];
    [updateButton setBezelStyle:NSBezelStyleRounded];
    [updateButton setTarget:self];
    [updateButton setAction:@selector(onPerformUpdateClicked:)];
    [updateButton setHidden:YES];
    [contentView addSubview:updateButton];

    updateProgressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 607, 735, 10)];
    [updateProgressIndicator setIndeterminate:NO];
    [updateProgressIndicator setMinValue:0.0];
    [updateProgressIndicator setMaxValue:100.0];
    [updateProgressIndicator setDoubleValue:0.0];
    [updateProgressIndicator setHidden:YES];
    [contentView addSubview:updateProgressIndicator];

    // ==================== 3. 手机反控中心 (FastMirror 局域网直连 + USB 专线) ====================
    NSBox* phoneBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, 480, 735, 120)];
    [phoneBox setTitle:@"📱 手机反控中心 (FastMirror 局域网直连 / USB 专线)"];
    [phoneBox setTitleFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];

    // --- 第 1 行：局域网 Wi-Fi IP 直连 ---
    NSTextField* ipLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 68, 95, 20)];
    [ipLabel setStringValue:@"局域网手机 IP:"];
    [ipLabel setFont:[NSFont systemFontOfSize:12]];
    [ipLabel setBezeled:NO];
    [ipLabel setDrawsBackground:NO];
    [ipLabel setEditable:NO];
    [phoneBox addSubview:ipLabel];

    ipTextField = [[NSTextField alloc] initWithFrame:NSMakeRect(112, 66, 120, 22)];
    [ipTextField setStringValue:@"192.168.2.3"];
    [ipTextField setPlaceholderString:@"192.168.x.x"];
    [ipTextField setFont:[NSFont fontWithName:@"Menlo" size:12] ?: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]];
    [phoneBox addSubview:ipTextField];

    NSTextField* portLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(238, 68, 38, 20)];
    [portLabel setStringValue:@"端口:"];
    [portLabel setFont:[NSFont systemFontOfSize:12]];
    [portLabel setBezeled:NO];
    [portLabel setDrawsBackground:NO];
    [portLabel setEditable:NO];
    [phoneBox addSubview:portLabel];

    portTextField = [[NSTextField alloc] initWithFrame:NSMakeRect(276, 66, 56, 22)];
    [portTextField setStringValue:@"19999"];
    [portTextField setFont:[NSFont fontWithName:@"Menlo" size:12] ?: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]];
    [phoneBox addSubview:portTextField];

    connectWifiBtn = [[NSButton alloc] initWithFrame:NSMakeRect(340, 62, 105, 28)];
    [connectWifiBtn setTitle:@"连接 Wi-Fi"];
    [connectWifiBtn setBezelStyle:NSBezelStyleRounded];
    [connectWifiBtn setTarget:self];
    [connectWifiBtn setAction:@selector(onConnectWifiClicked:)];
    [phoneBox addSubview:connectWifiBtn];

    wifiStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(455, 67, 265, 20)];
    [wifiStatusLabel setStringValue:@"Wi-Fi 状态: 未连接 (输入手机IP点击连接)"];
    [wifiStatusLabel setFont:[NSFont systemFontOfSize:11]];
    [wifiStatusLabel setTextColor:[NSColor secondaryLabelColor]];
    [wifiStatusLabel setBezeled:NO];
    [wifiStatusLabel setDrawsBackground:NO];
    [wifiStatusLabel setEditable:NO];
    [phoneBox addSubview:wifiStatusLabel];

    // --- 第 2 行：USB 通道与全局反控快捷键 ---
    usbStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 18, 300, 24)];
    [usbStatusLabel setStringValue:@"正在检测 USB 连接设备..."];
    [usbStatusLabel setFont:[NSFont systemFontOfSize:12]];
    [usbStatusLabel setBezeled:NO];
    [usbStatusLabel setDrawsBackground:NO];
    [usbStatusLabel setEditable:NO];
    [phoneBox addSubview:usbStatusLabel];

    NSButton* refreshUsbBtn = [[NSButton alloc] initWithFrame:NSMakeRect(320, 15, 85, 28)];
    [refreshUsbBtn setTitle:@"刷新 USB"];
    [refreshUsbBtn setBezelStyle:NSBezelStyleRounded];
    [refreshUsbBtn setTarget:self];
    [refreshUsbBtn setAction:@selector(onRefreshUsbClicked:)];
    [phoneBox addSubview:refreshUsbBtn];

    NSButton* backBtn = [[NSButton alloc] initWithFrame:NSMakeRect(410, 15, 95, 28)];
    [backBtn setTitle:@"返回 (Back)"];
    [backBtn setBezelStyle:NSBezelStyleRounded];
    [backBtn setTarget:self];
    [backBtn setAction:@selector(onUsbBackClicked:)];
    [phoneBox addSubview:backBtn];

    NSButton* homeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(510, 15, 95, 28)];
    [homeBtn setTitle:@"桌面 (Home)"];
    [homeBtn setBezelStyle:NSBezelStyleRounded];
    [homeBtn setTarget:self];
    [homeBtn setAction:@selector(onUsbHomeClicked:)];
    [phoneBox addSubview:homeBtn];

    NSButton* recentsBtn = [[NSButton alloc] initWithFrame:NSMakeRect(610, 15, 105, 28)];
    [recentsBtn setTitle:@"任务 (Tasks)"];
    [recentsBtn setBezelStyle:NSBezelStyleRounded];
    [recentsBtn setTarget:self];
    [recentsBtn setAction:@selector(onRecentsClicked:)];
    [phoneBox addSubview:recentsBtn];

    [contentView addSubview:phoneBox];

    // ==================== 4. 运行状态与事件日志视窗 (宽敞全高显示) ====================
    NSTextField* logTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 440, 200, 20)];
    [logTitle setStringValue:@"📋 运行状态与事件日志"];
    [logTitle setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];
    [logTitle setBezeled:NO];
    [logTitle setDrawsBackground:NO];
    [logTitle setEditable:NO];
    [contentView addSubview:logTitle];

    NSButton* clearLogBtn = [[NSButton alloc] initWithFrame:NSMakeRect(670, 437, 85, 26)];
    [clearLogBtn setTitle:@"清空"];
    [clearLogBtn setBezelStyle:NSBezelStyleRounded];
    [clearLogBtn setTarget:self];
    [clearLogBtn setAction:@selector(onClearLogClicked:)];
    [contentView addSubview:clearLogBtn];

    NSScrollView* logScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 735, 410)];
    [logScrollView setHasVerticalScroller:YES];
    [logScrollView setBorderType:NSBezelBorder];

    logTextView = [[NSTextView alloc] initWithFrame:[logScrollView bounds]];
    [logTextView setEditable:NO];
    [logTextView setFont:[NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [logTextView setBackgroundColor:[NSColor colorWithCalibratedRed:0.11 green:0.12 blue:0.13 alpha:1.0]];
    [logTextView setTextColor:[NSColor colorWithCalibratedRed:0.92 green:0.92 blue:0.95 alpha:1.0]];
    [logTextView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [logScrollView setDocumentView:logTextView];
    [contentView addSubview:logScrollView];

    // 绑定控制器日志与状态更新
    auto& ctl = acast::desktop::DesktopController::GetInstance();
    __weak typeof(self) weakSelf = self;

    ctl.SetLogCallback([weakSelf](std::string msg) {
        NSString* text = [NSString stringWithUTF8String:msg.c_str()] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->logTextView) return;
            NSAttributedString* str = [[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n"]
                                                                      attributes:@{NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.92 green:0.92 blue:0.95 alpha:1.0],
                                                                                   NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]}];
            [[strongSelf->logTextView textStorage] appendAttributedString:str];
            [strongSelf->logTextView scrollRangeToVisible:NSMakeRange([[strongSelf->logTextView string] length], 0)];
        });
    });

    ctl.SetFastMirrorCallback([weakSelf](bool connected, std::string addr) {
        NSString* addrStr = [NSString stringWithUTF8String:addr.c_str()] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->wifiStatusLabel || !strongSelf->connectWifiBtn) return;
            if (connected) {
                [strongSelf->wifiStatusLabel setStringValue:[NSString stringWithFormat:@"Wi-Fi 状态: 已连接 (%@) [超低延迟反控]", addrStr]];
                [strongSelf->wifiStatusLabel setTextColor:[NSColor systemGreenColor]];
                [strongSelf->connectWifiBtn setTitle:@"断开直连"];
            } else {
                [strongSelf->wifiStatusLabel setStringValue:@"Wi-Fi 状态: 未连接 (输入手机IP点击连接)"];
                [strongSelf->wifiStatusLabel setTextColor:[NSColor secondaryLabelColor]];
                [strongSelf->connectWifiBtn setTitle:@"连接 Wi-Fi"];
            }
        });
    });

    ctl.SetUsbDeviceCallback([weakSelf](std::vector<acast::adb::AdbDevice> devices) {
        BOOL empty = devices.empty();
        NSString* desc = nil;
        if (!empty) {
            std::string d = "USB 已连接: " + devices[0].model + " (" + devices[0].serial + ") [通道已就绪]";
            desc = [NSString stringWithUTF8String:d.c_str()];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->usbStatusLabel) return;
            if (empty) {
                [strongSelf->usbStatusLabel setStringValue:@"USB 状态: 未检测到手机 (支持无线或插线)"];
                [strongSelf->usbStatusLabel setTextColor:[NSColor secondaryLabelColor]];
            } else {
                [strongSelf->usbStatusLabel setStringValue:desc ?: @""];
                [strongSelf->usbStatusLabel setTextColor:[NSColor systemGreenColor]];
            }
        });
    });

    ctl.SetUpdateCallback([weakSelf](acast::updater::UpdateInfo info) {
        BOOL hasUpdate = info.has_update;
        NSString* latestVer = [NSString stringWithUTF8String:info.latest_version.c_str()] ?: @"";
        NSString* currentVer = [NSString stringWithUTF8String:info.current_version.c_str()] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->updateBannerLabel || !strongSelf->updateButton) return;
            if (hasUpdate) {
                NSString* banner = [NSString stringWithFormat:@"🎉 发现新版本: %@ (当前: %@)", latestVer, currentVer];
                [strongSelf->updateBannerLabel setStringValue:banner];
                [strongSelf->updateBannerLabel setHidden:NO];
                [strongSelf->updateButton setHidden:NO];
            } else {
                [strongSelf->updateBannerLabel setHidden:YES];
                [strongSelf->updateButton setHidden:YES];
            }
        });
    });

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // 核心后台服务在 UI 视窗完全就绪后再启动
    ctl.Init();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    acast::desktop::DesktopController::GetInstance().Cleanup();
}

#pragma mark - UI Actions

- (void)onCheckUpdateClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().CheckUpdateAsync();
}

- (void)onPerformUpdateClicked:(id)sender {
    [updateButton setEnabled:NO];
    [updateProgressIndicator setHidden:NO];
    [updateProgressIndicator setDoubleValue:10.0];

    __weak typeof(self) weakSelf = self;
    acast::desktop::DesktopController::GetInstance().PerformUpdateAsync([weakSelf](std::string status, int progress) {
        NSString* statusStr = [NSString stringWithUTF8String:status.c_str()] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->updateProgressIndicator setDoubleValue:(double)progress];
            if (progress >= 100) {
                [strongSelf->updateBannerLabel setStringValue:statusStr];
            }
        });
    });
}

- (void)onConnectWifiClicked:(id)sender {
    auto& ctl = acast::desktop::DesktopController::GetInstance();
    if (ctl.IsWifiPhoneConnected()) {
        ctl.DisconnectWifiPhone();
    } else {
        NSString* ip = [ipTextField stringValue];
        NSString* portStr = [portTextField stringValue];
        uint16_t port = [portStr intValue] > 0 ? (uint16_t)[portStr intValue] : 19999;
        ctl.ConnectWifiPhone([ip UTF8String], port);
    }
}

- (void)onRefreshUsbClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().RefreshUsbDevices();
}

- (void)onUsbBackClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().SendBackKey();
}

- (void)onUsbHomeClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().SendHomeKey();
}

- (void)onRecentsClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().SendRecentsKey();
}

- (void)onClearLogClicked:(id)sender {
    [[logTextView textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
}

@end

namespace acast {
namespace desktop {

static AppDelegate* g_appDelegate = nil;

int RunDesktopApp(int argc, char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        g_appDelegate = [[AppDelegate alloc] init];
        [app setDelegate:g_appDelegate];

        // 构造标准的 macOS 应用菜单 (Quit 等快捷键)
        NSMenu* menubar = [[NSMenu alloc] init];
        NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
        [menubar addItem:appMenuItem];
        [app setMainMenu:menubar];

        NSMenu* appMenu = [[NSMenu alloc] init];
        NSString* quitTitle = [@"退出 " stringByAppendingString:@"ACast"];
        NSMenuItem* quitMenuItem = [[NSMenuItem alloc] initWithTitle:quitTitle
                                                             action:@selector(terminate:)
                                                      keyEquivalent:@"q"];
        [appMenu addItem:quitMenuItem];
        [appMenuItem setSubmenu:appMenu];

        [app run];
    }
    return 0;
}

} // namespace desktop
} // namespace acast

#endif // __APPLE__
