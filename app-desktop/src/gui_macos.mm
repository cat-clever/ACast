#if defined(__APPLE__)

#import <Cocoa/Cocoa.h>
#include "gui_interface.h"
#include "desktop_controller.h"
#include "auto_updater.h"
#include <vector>
#include <string>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate> {
    NSWindow* window;
    NSTextView* logTextView;
    NSTableView* tvTableView;
    NSTextField* updateBannerLabel;
    NSButton* updateButton;
    NSTextField* usbStatusLabel;
    NSProgressIndicator* updateProgressIndicator;
    NSMutableArray<NSDictionary<NSString*, NSString*>*>* tvDevicesList;
}
@end

@implementation AppDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        tvDevicesList = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSRect frame = NSMakeRect(0, 0, 780, 640);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:style
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setTitle:@"ACast 跨平台投屏控制台"];
    [window setMinSize:NSMakeSize(680, 520)];
    [window center];

    NSView* contentView = [window contentView];

    // ==================== 1. 顶部 Header ====================
    NSTextField* titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 595, 300, 30)];
    [titleLabel setStringValue:@"ACast 跨平台投屏控制端"];
    [titleLabel setFont:[NSFont systemFontOfSize:17 weight:NSFontWeightBold]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [contentView addSubview:titleLabel];

    NSTextField* versionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(280, 597, 120, 24)];
    std::string verStr = std::string("v") + acast::updater::AutoUpdater::CURRENT_VERSION;
    [versionLabel setStringValue:[NSString stringWithUTF8String:verStr.c_str()]];
    [versionLabel setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
    [versionLabel setTextColor:[NSColor secondaryLabelColor]];
    [versionLabel setBezeled:NO];
    [versionLabel setDrawsBackground:NO];
    [versionLabel setEditable:NO];
    [versionLabel setSelectable:NO];
    [contentView addSubview:versionLabel];

    NSButton* checkUpdateBtn = [[NSButton alloc] initWithFrame:NSMakeRect(640, 595, 115, 30)];
    [checkUpdateBtn setTitle:@"检查更新"];
    [checkUpdateBtn setBezelStyle:NSBezelStyleRounded];
    [checkUpdateBtn setTarget:self];
    [checkUpdateBtn setAction:@selector(onCheckUpdateClicked:)];
    [contentView addSubview:checkUpdateBtn];

    // ==================== 2. 更新横幅 (默认隐藏) ====================
    updateBannerLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 560, 580, 24)];
    [updateBannerLabel setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    [updateBannerLabel setTextColor:[NSColor systemGreenColor]];
    [updateBannerLabel setBezeled:NO];
    [updateBannerLabel setDrawsBackground:NO];
    [updateBannerLabel setEditable:NO];
    [updateBannerLabel setHidden:YES];
    [contentView addSubview:updateBannerLabel];

    updateButton = [[NSButton alloc] initWithFrame:NSMakeRect(620, 558, 135, 28)];
    [updateButton setTitle:@"原地热更新"];
    [updateButton setBezelStyle:NSBezelStyleRounded];
    [updateButton setTarget:self];
    [updateButton setAction:@selector(onPerformUpdateClicked:)];
    [updateButton setHidden:YES];
    [contentView addSubview:updateButton];

    updateProgressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 555, 735, 10)];
    [updateProgressIndicator setIndeterminate:NO];
    [updateProgressIndicator setMinValue:0.0];
    [updateProgressIndicator setMaxValue:100.0];
    [updateProgressIndicator setDoubleValue:0.0];
    [updateProgressIndicator setHidden:YES];
    [contentView addSubview:updateProgressIndicator];

    // ==================== 3. USB 手机反控卡片 ====================
    NSBox* usbBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, 465, 735, 85)];
    [usbBox setTitle:@"📱 USB 手机连接与高速反控"];
    [usbBox setTitleFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];

    usbStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 20, 420, 28)];
    [usbStatusLabel setStringValue:@"正在检测 USB 连接设备..."];
    [usbStatusLabel setFont:[NSFont systemFontOfSize:12]];
    [usbStatusLabel setBezeled:NO];
    [usbStatusLabel setDrawsBackground:NO];
    [usbStatusLabel setEditable:NO];
    [usbBox addSubview:usbStatusLabel];

    NSButton* refreshUsbBtn = [[NSButton alloc] initWithFrame:NSMakeRect(445, 18, 90, 30)];
    [refreshUsbBtn setTitle:@"刷新 USB"];
    [refreshUsbBtn setBezelStyle:NSBezelStyleRounded];
    [refreshUsbBtn setTarget:self];
    [refreshUsbBtn setAction:@selector(onRefreshUsbClicked:)];
    [usbBox addSubview:refreshUsbBtn];

    NSButton* backBtn = [[NSButton alloc] initWithFrame:NSMakeRect(540, 18, 85, 30)];
    [backBtn setTitle:@"返回 (Back)"];
    [backBtn setBezelStyle:NSBezelStyleRounded];
    [backBtn setTarget:self];
    [backBtn setAction:@selector(onUsbBackClicked:)];
    [usbBox addSubview:backBtn];

    NSButton* homeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(630, 18, 85, 30)];
    [homeBtn setTitle:@"桌面 (Home)"];
    [homeBtn setBezelStyle:NSBezelStyleRounded];
    [homeBtn setTarget:self];
    [homeBtn setAction:@selector(onUsbHomeClicked:)];
    [usbBox addSubview:homeBtn];

    [contentView addSubview:usbBox];

    // ==================== 4. 局域网大屏设备卡片 ====================
    NSBox* tvBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, 275, 735, 180)];
    [tvBox setTitle:@"📺 局域网大屏设备 (DLNA / Cast / AirPlay)"];
    [tvBox setTitleFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];

    NSButton* refreshTvBtn = [[NSButton alloc] initWithFrame:NSMakeRect(620, 125, 100, 30)];
    [refreshTvBtn setTitle:@"搜索大屏"];
    [refreshTvBtn setBezelStyle:NSBezelStyleRounded];
    [refreshTvBtn setTarget:self];
    [refreshTvBtn setAction:@selector(onRefreshTvClicked:)];
    [tvBox addSubview:refreshTvBtn];

    NSScrollView* tableScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(15, 15, 700, 105)];
    [tableScrollView setHasVerticalScroller:YES];
    [tableScrollView setBorderType:NSBezelBorder];

    tvTableView = [[NSTableView alloc] initWithFrame:[tableScrollView bounds]];
    NSTableColumn* colName = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[colName headerCell] setStringValue:@"设备名称 / 协议支持"];
    [colName setWidth:380];
    [tvTableView addTableColumn:colName];

    NSTableColumn* colIp = [[NSTableColumn alloc] initWithIdentifier:@"ip"];
    [[colIp headerCell] setStringValue:@"局域网 IP / 控制端点"];
    [colIp setWidth:300];
    [tvTableView addTableColumn:colIp];

    [tvTableView setDataSource:self];
    [tvTableView setDelegate:self];
    [tableScrollView setDocumentView:tvTableView];
    [tvBox addSubview:tableScrollView];

    [contentView addSubview:tvBox];

    // ==================== 5. 底部运行日志视窗 ====================
    NSTextField* logTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 240, 200, 20)];
    [logTitle setStringValue:@"📋 运行状态与事件日志"];
    [logTitle setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];
    [logTitle setBezeled:NO];
    [logTitle setDrawsBackground:NO];
    [logTitle setEditable:NO];
    [contentView addSubview:logTitle];

    NSButton* clearLogBtn = [[NSButton alloc] initWithFrame:NSMakeRect(670, 237, 85, 26)];
    [clearLogBtn setTitle:@"清空"];
    [clearLogBtn setBezelStyle:NSBezelStyleRounded];
    [clearLogBtn setTarget:self];
    [clearLogBtn setAction:@selector(onClearLogClicked:)];
    [contentView addSubview:clearLogBtn];

    NSScrollView* logScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 735, 215)];
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

    // ==================== 6. 注册 Controller 弱引用线程安全回调 ====================
    auto& ctl = acast::desktop::DesktopController::GetInstance();
    __weak typeof(self) weakSelf = self;

    ctl.SetLogCallback([weakSelf](std::string line) {
        NSString* text = [NSString stringWithUTF8String:(line + "\n").c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->logTextView) return;
            NSAttributedString* attr = [[NSAttributedString alloc] initWithString:text attributes:@{
                NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.85 green:0.90 blue:0.95 alpha:1.0],
                NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
            }];
            [[strongSelf->logTextView textStorage] appendAttributedString:attr];
            [strongSelf->logTextView scrollRangeToVisible:NSMakeRange([[strongSelf->logTextView string] length], 0)];
        });
    });

    ctl.SetTvDeviceCallback([weakSelf](std::vector<acast::dlna::DlnaDevice> devices) {
        NSMutableArray* array = [[NSMutableArray alloc] initWithCapacity:devices.size()];
        for (const auto& dev : devices) {
            NSString* name = [NSString stringWithUTF8String:dev.friendly_name.c_str()] ?: @"未知设备";
            std::string ep = dev.ip_address + "  (" + dev.control_url + ")";
            NSString* endpoint = [NSString stringWithUTF8String:ep.c_str()] ?: @"";
            [array addObject:@{@"name": name, @"endpoint": endpoint}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->tvTableView) return;
            strongSelf->tvDevicesList = array;
            [strongSelf->tvTableView reloadData];
        });
    });

    ctl.SetUsbDeviceCallback([weakSelf](std::vector<acast::adb::AdbDevice> devices) {
        BOOL empty = devices.empty();
        NSString* desc = nil;
        if (!empty) {
            std::string d = "已连接: " + devices[0].model + " (" + devices[0].serial + ") [高速反控通道已建立]";
            desc = [NSString stringWithUTF8String:d.c_str()];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->usbStatusLabel) return;
            if (empty) {
                [strongSelf->usbStatusLabel setStringValue:@"未检测到 USB 手机 (请开启 USB 调试并插入数据线)"];
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

- (void)onRefreshUsbClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().RefreshUsbDevices();
}

- (void)onUsbBackClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().SendUsbBack();
}

- (void)onUsbHomeClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().SendUsbHome();
}

- (void)onRefreshTvClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().RefreshTvDevices();
}

- (void)onClearLogClicked:(id)sender {
    [[logTextView textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
}

#pragma mark - NSTableViewDataSource & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)[tvDevicesList count];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)[tvDevicesList count]) return nil;
    NSDictionary* dev = tvDevicesList[row];

    NSTextField* cell = [tableView makeViewWithIdentifier:[tableColumn identifier] owner:self];
    if (!cell) {
        cell = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, [tableColumn width], 20)];
        [cell setIdentifier:[tableColumn identifier]];
        [cell setBezeled:NO];
        [cell setDrawsBackground:NO];
        [cell setEditable:NO];
        [cell setSelectable:YES];
        [cell setFont:[NSFont systemFontOfSize:12]];
    }

    if ([[tableColumn identifier] isEqualToString:@"name"]) {
        [cell setStringValue:dev[@"name"] ?: @""];
        [cell setTextColor:[NSColor labelColor]];
    } else {
        [cell setStringValue:dev[@"endpoint"] ?: @""];
        [cell setTextColor:[NSColor secondaryLabelColor]];
    }

    return cell;
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
