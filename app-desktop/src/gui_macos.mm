#if defined(__APPLE__)

#import <Cocoa/Cocoa.h>
#include "gui_interface.h"
#include "desktop_controller.h"
#include "auto_updater.h"
#include <vector>
#include <string>
#include <memory>

static NSString* SafeStr(const std::string& str) {
    if (str.empty()) return @"";
    NSString* ns = [NSString stringWithUTF8String:str.c_str()];
    if (!ns) {
        ns = [[NSString alloc] initWithBytes:str.data() length:str.size() encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    return ns;
}

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    NSWindow* window;
    NSTextView* logTextView;
    NSTextField* updateBannerLabel;
    NSButton* updateButton;
    NSTextField* phoneStatusLabel;
    NSPopUpButton* phonePopUp;
    NSButton* connectPhoneBtn;
    NSTextField* usbStatusLabel;
    NSProgressIndicator* updateProgressIndicator;

    std::vector<acast::discovery::DiscoveredPhone> cachedWifiPhones;
    std::vector<acast::adb::AdbDevice> cachedUsbDevices;
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
    [versionLabel setStringValue:SafeStr(verStr)];
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
    updateBannerLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 612, 635, 24)];
    [updateBannerLabel setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    [updateBannerLabel setTextColor:[NSColor systemGreenColor]];
    [updateBannerLabel setBezeled:NO];
    [updateBannerLabel setDrawsBackground:NO];
    [updateBannerLabel setEditable:NO];
    [updateBannerLabel setHidden:YES];
    [contentView addSubview:updateBannerLabel];

    updateButton = [[NSButton alloc] initWithFrame:NSMakeRect(665, 610, 90, 28)];
    [updateButton setTitle:@"更新"];
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

    // ==================== 3. 手机反控中心 (自动发现 / 下拉选择手机) ====================
    NSBox* phoneBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, 480, 735, 120)];
    [phoneBox setTitle:@"📱 手机反控中心 (局域网对等直连 / USB 专线)"];
    [phoneBox setTitleFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];

    // --- 第 1 行：手机设备选择与连接 ---
    NSTextField* selectLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 68, 90, 20)];
    [selectLabel setStringValue:@"选择手机设备:"];
    [selectLabel setFont:[NSFont systemFontOfSize:12]];
    [selectLabel setBezeled:NO];
    [selectLabel setDrawsBackground:NO];
    [selectLabel setEditable:NO];
    [phoneBox addSubview:selectLabel];

    phonePopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(105, 64, 255, 26) pullsDown:NO];
    [phonePopUp addItemWithTitle:@"(正在自动搜寻局域网手机...)"];
    [phoneBox addSubview:phonePopUp];

    connectPhoneBtn = [[NSButton alloc] initWithFrame:NSMakeRect(368, 62, 95, 28)];
    [connectPhoneBtn setTitle:@"连接手机"];
    [connectPhoneBtn setBezelStyle:NSBezelStyleRounded];
    [connectPhoneBtn setTarget:self];
    [connectPhoneBtn setAction:@selector(onConnectPhoneClicked:)];
    [phoneBox addSubview:connectPhoneBtn];

    NSButton* refreshPhoneBtn = [[NSButton alloc] initWithFrame:NSMakeRect(468, 62, 85, 28)];
    [refreshPhoneBtn setTitle:@"刷新搜索"];
    [refreshPhoneBtn setBezelStyle:NSBezelStyleRounded];
    [refreshPhoneBtn setTarget:self];
    [refreshPhoneBtn setAction:@selector(onRefreshPhoneClicked:)];
    [phoneBox addSubview:refreshPhoneBtn];

    phoneStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(560, 67, 165, 20)];
    [phoneStatusLabel setStringValue:@"状态: 未连接"];
    [phoneStatusLabel setFont:[NSFont systemFontOfSize:11]];
    [phoneStatusLabel setTextColor:[NSColor secondaryLabelColor]];
    [phoneStatusLabel setBezeled:NO];
    [phoneStatusLabel setDrawsBackground:NO];
    [phoneStatusLabel setEditable:NO];
    [phoneBox addSubview:phoneStatusLabel];

    // --- 第 2 行：USB 状态与全局快捷控制按键 ---
    usbStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 18, 385, 24)];
    [usbStatusLabel setStringValue:@"正在检测 USB 连接设备..."];
    [usbStatusLabel setFont:[NSFont systemFontOfSize:12]];
    [usbStatusLabel setBezeled:NO];
    [usbStatusLabel setDrawsBackground:NO];
    [usbStatusLabel setEditable:NO];
    [phoneBox addSubview:usbStatusLabel];

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
    [logTextView setBackgroundColor:[NSColor controlBackgroundColor]];
    [logTextView setTextColor:[NSColor textColor]];
    [logTextView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    [logScrollView setDocumentView:logTextView];
    [contentView addSubview:logScrollView];

    [window makeKeyAndOrderFront:nil];

    // ==================== 5. 绑定控制器回调 ====================
    auto& ctl = acast::desktop::DesktopController::GetInstance();

    __weak typeof(self) weakSelf = self;
    ctl.SetLogCallback([weakSelf](const std::string& line) {
        NSString* text = SafeStr(line);
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            NSAttributedString* attr = [[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n"]];
            [[strongSelf->logTextView textStorage] appendAttributedString:attr];
            [strongSelf->logTextView scrollToEndOfDocument:nil];
        });
    });

    ctl.SetFastMirrorCallback([weakSelf](bool connected, std::string address) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            if (connected) {
                [strongSelf->phoneStatusLabel setStringValue:@"🎉 已直连 (<20ms)"];
                [strongSelf->phoneStatusLabel setTextColor:[NSColor systemGreenColor]];
                [strongSelf->connectPhoneBtn setTitle:@"断开连接"];
            } else {
                [strongSelf->phoneStatusLabel setStringValue:@"状态: 未连接"];
                [strongSelf->phoneStatusLabel setTextColor:[NSColor secondaryLabelColor]];
                [strongSelf->connectPhoneBtn setTitle:@"连接手机"];
            }
        });
    });

    // 采用 make_shared 延长 C++ 数据的生命周期，彻底杜绝 GCD 异步访问悬垂野指针
    ctl.SetDiscoveredPhonesCallback([weakSelf](std::vector<acast::discovery::DiscoveredPhone> phones) {
        auto pPhones = std::make_shared<std::vector<acast::discovery::DiscoveredPhone>>(std::move(phones));
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->cachedWifiPhones = *pPhones;
            [strongSelf reloadDevicePopUp];
        });
    });

    ctl.SetUsbDeviceCallback([weakSelf](std::vector<acast::adb::AdbDevice> devices) {
        auto pDevs = std::make_shared<std::vector<acast::adb::AdbDevice>>(std::move(devices));
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->cachedUsbDevices = *pDevs;
            [strongSelf reloadDevicePopUp];

            if (pDevs->empty()) {
                [strongSelf->usbStatusLabel setStringValue:@"USB 状态: 未检测到手机 (支持无线或插线)"];
            } else {
                std::string desc = "USB 已连接: " + (*pDevs)[0].model + " (" + (*pDevs)[0].serial + ") [通道已就绪]";
                [strongSelf->usbStatusLabel setStringValue:SafeStr(desc)];
            }
        });
    });

    ctl.SetUpdateCallback([weakSelf](acast::updater::UpdateInfo info) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            if (info.has_update) {
                NSString* banner = [NSString stringWithFormat:@"🎉 发现新版本: %@ (当前: %@) 点击【更新】自动升级！",
                                    SafeStr(info.latest_version),
                                    SafeStr(acast::updater::AutoUpdater::CURRENT_VERSION)];
                [strongSelf->updateBannerLabel setStringValue:banner];
                [strongSelf->updateBannerLabel setHidden:NO];
                [strongSelf->updateButton setHidden:NO];
            }
        });
    });

    ctl.Init();
    ctl.RefreshPhones();
}

- (void)reloadDevicePopUp {
    NSString* currentSelectedTitle = [phonePopUp titleOfSelectedItem];
    [phonePopUp removeAllItems];

    NSInteger count = 0;

    // 1. 添加自动发现的局域网 Wi-Fi 手机
    for (const auto& phone : cachedWifiPhones) {
        NSString* nameStr = SafeStr(phone.name);
        NSString* ipStr = SafeStr(phone.ip);
        if ([nameStr length] == 0) nameStr = @"Android 手机";
        if ([ipStr length] == 0) continue;

        NSString* title = [NSString stringWithFormat:@"📱 %@ (%@)", nameStr, ipStr];
        [phonePopUp addItemWithTitle:title];
        NSMenuItem* item = [phonePopUp lastItem];
        [item setRepresentedObject:@{
            @"type": @"wifi",
            @"ip": ipStr,
            @"port": @(phone.port > 0 ? phone.port : 19999)
        }];
        count++;
    }

    // 2. 添加 USB 专线连入的手机
    for (const auto& dev : cachedUsbDevices) {
        NSString* modelStr = SafeStr(dev.model);
        NSString* serialStr = SafeStr(dev.serial);
        if ([modelStr length] == 0) modelStr = @"Android 设备";
        if ([serialStr length] == 0) continue;

        NSString* title = [NSString stringWithFormat:@"🔌 %@ (USB 专线)", modelStr];
        [phonePopUp addItemWithTitle:title];
        NSMenuItem* item = [phonePopUp lastItem];
        [item setRepresentedObject:@{
            @"type": @"usb",
            @"serial": serialStr
        }];
        count++;
    }

    if (count == 0) {
        [phonePopUp addItemWithTitle:@"(未发现手机，请确保手机已开启投屏)"];
        [[phonePopUp lastItem] setEnabled:NO];
    } else {
        if (currentSelectedTitle && [phonePopUp itemWithTitle:currentSelectedTitle]) {
            [phonePopUp selectItemWithTitle:currentSelectedTitle];
        }
    }
}

- (void)onConnectPhoneClicked:(id)sender {
    auto& ctl = acast::desktop::DesktopController::GetInstance();
    if (ctl.IsWifiPhoneConnected()) {
        ctl.DisconnectWifiPhone();
        return;
    }

    NSMenuItem* selectedItem = [phonePopUp selectedItem];
    if (!selectedItem) return;

    NSDictionary* dict = [selectedItem representedObject];
    if (!dict) {
        ctl.Log("[控制端] 请选择有效的手机设备进行连接！");
        return;
    }

    NSString* type = dict[@"type"];
    if ([type isEqualToString:@"wifi"]) {
        NSString* ip = dict[@"ip"];
        uint16_t port = [dict[@"port"] unsignedShortValue];
        ctl.ConnectWifiPhone([ip UTF8String], port);
    } else if ([type isEqualToString:@"usb"]) {
        NSString* serial = dict[@"serial"];
        ctl.Log("[控制端] 正在切换至 USB 专线反控: " + std::string([serial UTF8String]));
        ctl.RefreshUsbDevices();
    }
}

- (void)onRefreshPhoneClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().RefreshPhones();
}

- (void)onCheckUpdateClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().CheckUpdateAsync();
}

- (void)onPerformUpdateClicked:(id)sender {
    [updateButton setEnabled:NO];
    [updateProgressIndicator setHidden:NO];
    [updateProgressIndicator setDoubleValue:10.0];

    __weak typeof(self) weakSelf = self;
    acast::desktop::DesktopController::GetInstance().PerformUpdateAsync([weakSelf](std::string status, int progress) {
        NSString* statusStr = SafeStr(status);
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
