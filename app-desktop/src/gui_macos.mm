#if defined(__APPLE__)

#import <Cocoa/Cocoa.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>

#include "gui_interface.h"
#include "desktop_controller.h"
#include "auto_updater.h"
#include <vector>
#include <string>
#include <memory>
#include <algorithm>
#include <arpa/inet.h>

static NSString* SafeStr(const std::string& str) {
    if (str.empty()) return @"";
    NSString* ns = [NSString stringWithUTF8String:str.c_str()];
    if (!ns) {
        ns = [[NSString alloc] initWithBytes:str.data() length:str.size() encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    return ns;
}

// ============================================================================
// ScreenMirrorView: 极低延迟硬件解码投屏视窗，支持鼠标触控滑动与电脑键盘直接输入
// ============================================================================

@interface ScreenMirrorView : NSView <NSTextInputClient> {
    CGImageRef currentFrameImage;
    CGImageRef pendingFrameImage;
    std::mutex frameLock;
    std::atomic<bool> renderScheduled;
    VTDecompressionSessionRef decompressionSession;
    CMVideoFormatDescriptionRef formatDescription;
    std::vector<uint8_t> spsData;
    std::vector<uint8_t> ppsData;
    NSRect lastAspectFitRect;
    std::chrono::steady_clock::time_point lastDragSendTime;

    NSMutableAttributedString* markedString;
    NSRange markedRange;
    NSRange selectedRange;
}

- (void)feedVideoPacket:(const uint8_t*)data size:(size_t)size isKey:(bool)isKey pts:(int64_t)pts;
- (void)deliverDecodedImage:(CGImageRef)image;
- (void)handleDecodeError:(OSStatus)status;
- (void)clearFrame;

@end

static void DecompressCallback(void* decompressionOutputRefCon,
                               void* sourceFrameRefCon,
                               OSStatus status,
                               VTDecodeInfoFlags infoFlags,
                               CVImageBufferRef imageBuffer,
                               CMTime presentationTimeStamp,
                               CMTime presentationDuration) {
    ScreenMirrorView* view = (__bridge ScreenMirrorView*)decompressionOutputRefCon;
    if (status == noErr && imageBuffer != NULL) {
        CGImageRef cgImage = NULL;
        VTCreateCGImageFromCVPixelBuffer(imageBuffer, NULL, &cgImage);
        if (cgImage != NULL) {
            [view deliverDecodedImage:cgImage];
        }
    } else if (status != noErr) {
        [view handleDecodeError:status];
    }
}

@implementation ScreenMirrorView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        currentFrameImage = NULL;
        pendingFrameImage = NULL;
        renderScheduled = false;
        decompressionSession = NULL;
        formatDescription = NULL;
        lastAspectFitRect = NSZeroRect;
        lastDragSendTime = std::chrono::steady_clock::now();
        markedString = nil;
        markedRange = NSMakeRange(NSNotFound, 0);
        selectedRange = NSMakeRange(0, 0);
    }
    return self;
}

- (void)dealloc {
    [self clearFrame];
    if (decompressionSession) {
        VTDecompressionSessionInvalidate(decompressionSession);
        CFRelease(decompressionSession);
        decompressionSession = NULL;
    }
    if (formatDescription) {
        CFRelease(formatDescription);
        formatDescription = NULL;
    }
}

- (void)clearFrame {
    {
        std::lock_guard<std::mutex> lock(frameLock);
        if (pendingFrameImage) {
            CGImageRelease(pendingFrameImage);
            pendingFrameImage = NULL;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->currentFrameImage) {
            CGImageRelease(self->currentFrameImage);
            self->currentFrameImage = NULL;
        }
        self->lastAspectFitRect = NSZeroRect;
        [self setNeedsDisplay:YES];
    });
}

- (void)handleDecodeError:(OSStatus)status {
    // 解码器状态异常自愈（如会话失效或脏帧）：重置会话，等待下一关键帧自动重建
    if (decompressionSession) {
        VTDecompressionSessionInvalidate(decompressionSession);
        CFRelease(decompressionSession);
        decompressionSession = NULL;
    }
}

- (void)deliverDecodedImage:(CGImageRef)image {
    // 零积压最新帧调度器：若渲染跟不上采集帧率，立即释放旧帧，只保留最新待渲染帧，杜绝内存风暴与 XPC 断连
    CGImageRef oldImage = NULL;
    {
        std::lock_guard<std::mutex> lock(frameLock);
        oldImage = pendingFrameImage;
        pendingFrameImage = image; // 暂存最新帧所有权
    }
    if (oldImage) {
        CGImageRelease(oldImage); // 立即释放未及渲染的旧帧，绝不积压
    }

    if (!renderScheduled.exchange(true)) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ScreenMirrorView* strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->renderScheduled = false;

            CGImageRef newFrame = NULL;
            {
                std::lock_guard<std::mutex> lock(strongSelf->frameLock);
                newFrame = strongSelf->pendingFrameImage;
                strongSelf->pendingFrameImage = NULL;
            }
            if (newFrame) {
                if (strongSelf->currentFrameImage) {
                    CGImageRelease(strongSelf->currentFrameImage);
                }
                strongSelf->currentFrameImage = newFrame;
                [strongSelf setNeedsDisplay:YES];
            }
        });
    }
}

- (void)feedVideoPacket:(const uint8_t*)data size:(size_t)size isKey:(bool)isKey pts:(int64_t)pts {
    if (!data || size < 4) return;

    struct NalUnit {
        const uint8_t* ptr;
        size_t size;
        uint8_t type;
    };

    std::vector<NalUnit> nals;
    size_t i = 0;
    while (i + 3 < size) {
        size_t startCodeLen = 0;
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            startCodeLen = 3;
        } else if (i + 4 <= size && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) {
            startCodeLen = 4;
        }

        if (startCodeLen > 0) {
            size_t nalStart = i + startCodeLen;
            size_t nextStart = size;
            for (size_t j = nalStart; j + 3 <= size; ++j) {
                if (data[j] == 0 && data[j+1] == 0 && (data[j+2] == 1 || (j + 4 <= size && data[j+2] == 0 && data[j+3] == 1))) {
                    nextStart = j;
                    break;
                }
            }
            if (nextStart > nalStart) {
                NalUnit u;
                u.ptr = data + nalStart;
                u.size = nextStart - nalStart;
                u.type = u.ptr[0] & 0x1F;
                nals.push_back(u);
            }
            i = nextStart;
        } else {
            i++;
        }
    }

    bool hasNewParams = false;
    for (const auto& nal : nals) {
        if (nal.type == 7) { // SPS
            if (spsData.size() != nal.size || memcmp(spsData.data(), nal.ptr, nal.size) != 0) {
                spsData.assign(nal.ptr, nal.ptr + nal.size);
                hasNewParams = true;
            }
        } else if (nal.type == 8) { // PPS
            if (ppsData.size() != nal.size || memcmp(ppsData.data(), nal.ptr, nal.size) != 0) {
                ppsData.assign(nal.ptr, nal.ptr + nal.size);
                hasNewParams = true;
            }
        }
    }

    if ((hasNewParams || decompressionSession == NULL || formatDescription == NULL) && !spsData.empty() && !ppsData.empty()) {
        if (decompressionSession) {
            VTDecompressionSessionInvalidate(decompressionSession);
            CFRelease(decompressionSession);
            decompressionSession = NULL;
        }
        if (formatDescription) {
            CFRelease(formatDescription);
            formatDescription = NULL;
        }

        const uint8_t* parameterSetPointers[2] = { spsData.data(), ppsData.data() };
        const size_t parameterSetSizes[2] = { spsData.size(), ppsData.size() };

        OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4, &formatDescription);

        if (status == noErr && formatDescription) {
            VTDecompressionOutputCallbackRecord cbRecord;
            cbRecord.decompressionOutputCallback = DecompressCallback;
            cbRecord.decompressionOutputRefCon = (__bridge void*)self;

            NSDictionary* destinationImageBufferAttributes = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferOpenGLCompatibilityKey: @(YES)
            };

            status = VTDecompressionSessionCreate(
                kCFAllocatorDefault, formatDescription, NULL,
                (__bridge CFDictionaryRef)destinationImageBufferAttributes,
                &cbRecord, &decompressionSession);

            if (status == noErr && decompressionSession) {
                VTSessionSetProperty(decompressionSession, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
            }
        }
    }

    std::vector<NalUnit> slices;
    for (const auto& nal : nals) {
        if (nal.type == 1 || nal.type == 5) {
            slices.push_back(nal);
        }
    }

    if (!slices.empty() && decompressionSession && formatDescription) {
        size_t totalAvccLen = 0;
        for (const auto& s : slices) totalAvccLen += 4 + s.size;
        uint8_t* avcc = (uint8_t*)malloc(totalAvccLen);
        if (avcc) {
            size_t off = 0;
            for (const auto& s : slices) {
                uint32_t lenBE = htonl((uint32_t)s.size);
                memcpy(avcc + off, &lenBE, 4);
                memcpy(avcc + off + 4, s.ptr, s.size);
                off += 4 + s.size;
            }

            CMBlockBufferRef blockBuffer = NULL;
            OSStatus status = CMBlockBufferCreateWithMemoryBlock(
                kCFAllocatorDefault, avcc, totalAvccLen, kCFAllocatorMalloc, NULL, 0, totalAvccLen, 0, &blockBuffer);

            if (status == noErr && blockBuffer) {
                CMSampleBufferRef sampleBuffer = NULL;
                CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
                status = CMSampleBufferCreate(
                    kCFAllocatorDefault, blockBuffer, TRUE, NULL, NULL, formatDescription, 1, 1, &timing, 0, NULL, &sampleBuffer);

                if (status == noErr && sampleBuffer) {
                    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
                    VTDecodeInfoFlags flagOut;
                    OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(decompressionSession, sampleBuffer, flags, NULL, &flagOut);
                    if (decodeStatus != noErr) {
                        [self handleDecodeError:decodeStatus];
                    }
                    CFRelease(sampleBuffer);
                }
                CFRelease(blockBuffer);
            } else {
                free(avcc);
            }
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] CGContext];
    NSRect bounds = [self bounds];

    // 绘制手机外框深色圆角容器
    NSBezierPath* bgPath = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:14 yRadius:14];
    [[NSColor colorWithCalibratedRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
    [bgPath fill];

    [[NSColor colorWithCalibratedWhite:0.22 alpha:0.9] setStroke];
    [bgPath setLineWidth:2.0];
    [bgPath stroke];

    if (currentFrameImage) {
        CGFloat imgW = CGImageGetWidth(currentFrameImage);
        CGFloat imgH = CGImageGetHeight(currentFrameImage);
        if (imgW > 0 && imgH > 0) {
            CGFloat scale = MIN(bounds.size.width / imgW, bounds.size.height / imgH);
            CGFloat fitW = imgW * scale;
            CGFloat fitH = imgH * scale;
            CGFloat fitX = bounds.origin.x + (bounds.size.width - fitW) * 0.5f;
            CGFloat fitY = bounds.origin.y + (bounds.size.height - fitH) * 0.5f;
            lastAspectFitRect = NSMakeRect(fitX, fitY, fitW, fitH);

            CGContextSaveGState(ctx);
            [bgPath addClip];
            CGContextDrawImage(ctx, NSRectToCGRect(lastAspectFitRect), currentFrameImage);
            CGContextRestoreGState(ctx);
            return;
        }
    }

    // 占位引导界面
    lastAspectFitRect = NSZeroRect;
    NSMutableParagraphStyle* pStyle = [[NSMutableParagraphStyle alloc] init];
    [pStyle setAlignment:NSTextAlignmentCenter];

    NSDictionary* titleAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: pStyle
    };
    NSDictionary* subAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.75 alpha:1.0],
        NSParagraphStyleAttributeName: pStyle
    };

    NSString* title = @"📱 实时手机投屏与反控视窗";
    [title drawInRect:NSMakeRect(15, bounds.size.height * 0.5 + 40, bounds.size.width - 30, 30) withAttributes:titleAttr];

    NSString* guide = @"等待手机连接推流中...\n\n在手机 ACast 点击【开启投屏】\n画面将在此实时呈现\n\n🖱️ 鼠标点击与拖拽滑动模拟触控\n⌨️ 电脑键盘直接输入文字与按键\n🖱️ 鼠标右键快速触发手机【返回】";
    [guide drawInRect:NSMakeRect(20, bounds.size.height * 0.5 - 110, bounds.size.width - 40, 140) withAttributes:subAttr];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)mouseDown:(NSEvent *)event {
    [[self window] makeFirstResponder:self];
    lastDragSendTime = std::chrono::steady_clock::now();
    [self sendNormalizedTouchWithEvent:event action:0]; // 0: DOWN (100% 立即发送)
}

- (void)mouseDragged:(NSEvent *)event {
    // 鼠标拖拽高频限流防背压：限制最低发送间隔为 16ms (约 60Hz)，杜绝高刷鼠标将 UI 主线程和 Socket 缓冲区阻塞拥死
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastDragSendTime).count();
    if (elapsed < 16) {
        return;
    }
    lastDragSendTime = now;
    [self sendNormalizedTouchWithEvent:event action:1]; // 1: MOVE
}

- (void)mouseUp:(NSEvent *)event {
    [self sendNormalizedTouchWithEvent:event action:2]; // 2: UP (100% 立即发送)
}

- (void)rightMouseDown:(NSEvent *)event {
    // 鼠标右键直接返回
    acast::desktop::DesktopController::GetInstance().SendBackKey();
}

- (void)sendNormalizedTouchWithEvent:(NSEvent *)event action:(uint8_t)action {
    if (NSIsEmptyRect(lastAspectFitRect)) return;
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];

    float normX = (loc.x - lastAspectFitRect.origin.x) / lastAspectFitRect.size.width;
    float normY = (NSMaxY(lastAspectFitRect) - loc.y) / lastAspectFitRect.size.height; // 翻转 Y 轴

    // 智能边界钳位：即使用户大幅左右滑出手机黑边，手势坐标也稳定在边缘，绝不丢弃滑动轨迹
    normX = std::max(0.0f, std::min(1.0f, normX));
    normY = std::max(0.0f, std::min(1.0f, normY));

    uint16_t nx = (uint16_t)(normX * 10000.0f);
    uint16_t ny = (uint16_t)(normY * 10000.0f);

    acast::desktop::DesktopController::GetInstance().SendTouch(action, nx, ny);
}

- (void)keyDown:(NSEvent *)event {
    // 1. 如果当前正处于中文拼音打字合成中，优先交由系统输入法处理候选词与选词上屏
    if ([self hasMarkedText]) {
        [[self inputContext] handleEvent:event];
        return;
    }

    unsigned short code = [event keyCode];
    auto& ctl = acast::desktop::DesktopController::GetInstance();

    // 2. 当没有处于输入法拼音状态时，拦截系统功能键 (ESC/Enter/Delete/方向键)
    if (code == 53) { // ESC -> 返回
        ctl.SendBackKey();
        return;
    } else if (code == 36) { // Return -> 回车
        ctl.SendKey(8);
        return;
    } else if (code == 51) { // Delete -> 退格删除
        ctl.SendKey(7);
        return;
    } else if (code == 126) { // Up
        ctl.SendKey(9);
        return;
    } else if (code == 125) { // Down
        ctl.SendKey(10);
        return;
    } else if (code == 123) { // Left
        ctl.SendKey(11);
        return;
    } else if (code == 124) { // Right
        ctl.SendKey(12);
        return;
    }

    // 3. 优先交由输入法上下文解释输入事件 (激活拼音/五笔等输入法浮窗)
    if (![[self inputContext] handleEvent:event]) {
        [self interpretKeyEvents:@[event]];
    }
}

// ==================== NSTextInputClient 协议实现 (支持中文汉字输入法) ====================

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString* textToInsert = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
    markedString = nil;
    markedRange = NSMakeRange(NSNotFound, 0);
    selectedRange = NSMakeRange(0, 0);

    if (textToInsert && [textToInsert length] > 0) {
        acast::desktop::DesktopController::GetInstance().SendTextInput([textToInsert UTF8String]);
    }
    [self setNeedsDisplay:YES];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)newSelectedRange replacementRange:(NSRange)replacementRange {
    if ([string isKindOfClass:[NSAttributedString class]]) {
        markedString = [[NSMutableAttributedString alloc] initWithAttributedString:string];
    } else {
        markedString = [[NSMutableAttributedString alloc] initWithString:string];
    }
    markedRange = NSMakeRange(0, [markedString length]);
    selectedRange = newSelectedRange;
    [self setNeedsDisplay:YES];
}

- (void)unmarkText {
    markedString = nil;
    markedRange = NSMakeRange(NSNotFound, 0);
    [self setNeedsDisplay:YES];
}

- (BOOL)hasMarkedText {
    return markedString != nil && [markedString length] > 0;
}

- (NSRange)markedRange {
    return markedString ? markedRange : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange {
    return selectedRange;
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange) *actualRange = range;
    return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return 0;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange) *actualRange = range;
    // 将中文拼音候选窗口精准定位在手机投屏视窗中下部，提供舒适自然的拼音选词视觉体验
    NSRect bounds = [self bounds];
    NSPoint centerPoint = NSMakePoint(NSMidX(bounds), std::max((CGFloat)60.0, NSMidY(bounds) - 120));
    NSPoint winPoint = [self convertPoint:centerPoint toView:nil];
    NSRect screenRect = [[self window] convertRectToScreen:NSMakeRect(winPoint.x, winPoint.y, 1, 1)];
    return screenRect;
}

- (void)doCommandBySelector:(SEL)selector {
    auto& ctl = acast::desktop::DesktopController::GetInstance();
    if (selector == @selector(deleteBackward:)) {
        ctl.SendKey(7);
    } else if (selector == @selector(insertNewline:)) {
        ctl.SendKey(8);
    } else if (selector == @selector(cancelOperation:)) {
        ctl.SendBackKey();
    } else if (selector == @selector(moveUp:)) {
        ctl.SendKey(9);
    } else if (selector == @selector(moveDown:)) {
        ctl.SendKey(10);
    } else if (selector == @selector(moveLeft:)) {
        ctl.SendKey(11);
    } else if (selector == @selector(moveRight:)) {
        ctl.SendKey(12);
    }
}

@end

// ============================================================================
// AppDelegate: 控制台主控制器
// ============================================================================

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    NSWindow* window;
    ScreenMirrorView* screenView;
    NSView* screenNavBar;
    NSButton* popScreenBtn;
    NSView* detachedPlaceholderView;
    NSWindow* standalonePhoneWindow;
    NSTextField* standaloneQuickInput;
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
    // 宽屏专业布局：宽 1160，高 730
    NSRect frame = NSMakeRect(0, 0, 1160, 730);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:style
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setTitle:@"ACast 跨平台投屏控制台"];
    [window setMinSize:NSMakeSize(1000, 680)];
    [window center];

    NSView* contentView = [window contentView];

    // ==================== 左侧：手机实时投屏与控制视窗 ====================
    popScreenBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 685, 420, 28)];
    [popScreenBtn setTitle:@"⤢ 弹出独立控制屏幕窗口"];
    [popScreenBtn setBezelStyle:NSBezelStyleRounded];
    [popScreenBtn setTarget:self];
    [popScreenBtn setAction:@selector(onPopStandaloneWindowClicked:)];
    [contentView addSubview:popScreenBtn];

    screenView = [[ScreenMirrorView alloc] initWithFrame:NSMakeRect(20, 62, 420, 615)];
    [screenView setAutoresizingMask:NSViewHeightSizable];
    [contentView addSubview:screenView];

    // 控制屏幕底部的虚拟导航三大键 (做在控制屏幕中)
    screenNavBar = [[NSView alloc] initWithFrame:NSMakeRect(20, 20, 420, 38)];
    [screenNavBar setWantsLayer:YES];
    screenNavBar.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.12 green:0.13 blue:0.15 alpha:1.0].CGColor;
    screenNavBar.layer.cornerRadius = 8.0;

    NSButton* mainNavBack = [[NSButton alloc] initWithFrame:NSMakeRect(15, 4, 120, 30)];
    [mainNavBack setTitle:@"◀ 返回 (Back)"];
    [mainNavBack setBezelStyle:NSBezelStyleRounded];
    [mainNavBack setTarget:self];
    [mainNavBack setAction:@selector(onUsbBackClicked:)];
    [screenNavBar addSubview:mainNavBack];

    NSButton* mainNavHome = [[NSButton alloc] initWithFrame:NSMakeRect(150, 4, 120, 30)];
    [mainNavHome setTitle:@"○ 桌面 (Home)"];
    [mainNavHome setBezelStyle:NSBezelStyleRounded];
    [mainNavHome setTarget:self];
    [mainNavHome setAction:@selector(onUsbHomeClicked:)];
    [screenNavBar addSubview:mainNavHome];

    NSButton* mainNavRecents = [[NSButton alloc] initWithFrame:NSMakeRect(285, 4, 120, 30)];
    [mainNavRecents setTitle:@"▢ 任务 (Tasks)"];
    [mainNavRecents setBezelStyle:NSBezelStyleRounded];
    [mainNavRecents setTarget:self];
    [mainNavRecents setAction:@selector(onRecentsClicked:)];
    [screenNavBar addSubview:mainNavRecents];

    [contentView addSubview:screenNavBar];

    // ==================== 独立窗口运行时主窗口占位视图 ====================
    detachedPlaceholderView = [[NSView alloc] initWithFrame:NSMakeRect(20, 20, 420, 657)];
    [detachedPlaceholderView setAutoresizingMask:NSViewHeightSizable];
    [detachedPlaceholderView setWantsLayer:YES];
    detachedPlaceholderView.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.09 green:0.10 blue:0.12 alpha:1.0].CGColor;
    detachedPlaceholderView.layer.cornerRadius = 10.0;
    detachedPlaceholderView.layer.borderWidth = 1.0;
    detachedPlaceholderView.layer.borderColor = [NSColor colorWithCalibratedRed:0.18 green:0.20 blue:0.24 alpha:1.0].CGColor;

    NSTextField* placeholderIcon = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 400, 380, 50)];
    [placeholderIcon setStringValue:@"🖥️"];
    [placeholderIcon setFont:[NSFont systemFontOfSize:42]];
    [placeholderIcon setAlignment:NSTextAlignmentCenter];
    [placeholderIcon setBezeled:NO];
    [placeholderIcon setDrawsBackground:NO];
    [placeholderIcon setEditable:NO];
    [placeholderIcon setSelectable:NO];
    [detachedPlaceholderView addSubview:placeholderIcon];

    NSTextField* placeholderTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 350, 380, 30)];
    [placeholderTitle setStringValue:@"独立控制屏幕视窗运行中"];
    [placeholderTitle setFont:[NSFont systemFontOfSize:16 weight:NSFontWeightBold]];
    [placeholderTitle setTextColor:[NSColor labelColor]];
    [placeholderTitle setAlignment:NSTextAlignmentCenter];
    [placeholderTitle setBezeled:NO];
    [placeholderTitle setDrawsBackground:NO];
    [placeholderTitle setEditable:NO];
    [placeholderTitle setSelectable:NO];
    [detachedPlaceholderView addSubview:placeholderTitle];

    NSTextField* placeholderDesc = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 275, 360, 65)];
    [placeholderDesc setStringValue:@"手机投屏画面与导航三大键已移至专属独立窗口。\n您可以在独立窗口中自由拖拽缩放、全屏高清观看及鼠标键盘操控。"];
    [placeholderDesc setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]];
    [placeholderDesc setTextColor:[NSColor secondaryLabelColor]];
    [placeholderDesc setAlignment:NSTextAlignmentCenter];
    [placeholderDesc setBezeled:NO];
    [placeholderDesc setDrawsBackground:NO];
    [placeholderDesc setEditable:NO];
    [placeholderDesc setSelectable:NO];
    [detachedPlaceholderView addSubview:placeholderDesc];

    NSButton* restoreBtn = [[NSButton alloc] initWithFrame:NSMakeRect(110, 215, 200, 36)];
    [restoreBtn setTitle:@"⤓ 收回控制屏幕至主窗口"];
    [restoreBtn setBezelStyle:NSBezelStyleRounded];
    [restoreBtn setTarget:self];
    [restoreBtn setAction:@selector(restoreMainScreenControl)];
    [detachedPlaceholderView addSubview:restoreBtn];

    [detachedPlaceholderView setHidden:YES];
    [contentView addSubview:detachedPlaceholderView];

    // ==================== 右侧控制区基准坐标 ====================
    CGFloat rightX = 460;
    CGFloat rightW = 680;

    // --- 1. 顶部 Header ---
    NSTextField* titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX, 685, 260, 30)];
    [titleLabel setStringValue:@"ACast 跨平台投屏控制端"];
    [titleLabel setFont:[NSFont systemFontOfSize:17 weight:NSFontWeightBold]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [contentView addSubview:titleLabel];

    NSTextField* versionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX + 250, 687, 100, 24)];
    std::string verStr = std::string("v") + acast::updater::AutoUpdater::CURRENT_VERSION;
    [versionLabel setStringValue:SafeStr(verStr)];
    [versionLabel setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
    [versionLabel setTextColor:[NSColor secondaryLabelColor]];
    [versionLabel setBezeled:NO];
    [versionLabel setDrawsBackground:NO];
    [versionLabel setEditable:NO];
    [versionLabel setSelectable:NO];
    [contentView addSubview:versionLabel];

    NSButton* checkUpdateBtn = [[NSButton alloc] initWithFrame:NSMakeRect(rightX + rightW - 110, 685, 110, 30)];
    [checkUpdateBtn setTitle:@"检查更新"];
    [checkUpdateBtn setBezelStyle:NSBezelStyleRounded];
    [checkUpdateBtn setTarget:self];
    [checkUpdateBtn setAction:@selector(onCheckUpdateClicked:)];
    [contentView addSubview:checkUpdateBtn];

    // --- 2. 更新横幅 ---
    updateBannerLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX, 652, rightW - 95, 24)];
    [updateBannerLabel setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    [updateBannerLabel setTextColor:[NSColor systemGreenColor]];
    [updateBannerLabel setBezeled:NO];
    [updateBannerLabel setDrawsBackground:NO];
    [updateBannerLabel setEditable:NO];
    [updateBannerLabel setHidden:YES];
    [contentView addSubview:updateBannerLabel];

    updateButton = [[NSButton alloc] initWithFrame:NSMakeRect(rightX + rightW - 90, 650, 90, 28)];
    [updateButton setTitle:@"更新"];
    [updateButton setBezelStyle:NSBezelStyleRounded];
    [updateButton setTarget:self];
    [updateButton setAction:@selector(onPerformUpdateClicked:)];
    [updateButton setHidden:YES];
    [contentView addSubview:updateButton];

    updateProgressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(rightX, 647, rightW, 8)];
    [updateProgressIndicator setIndeterminate:NO];
    [updateProgressIndicator setMinValue:0.0];
    [updateProgressIndicator setMaxValue:100.0];
    [updateProgressIndicator setDoubleValue:0.0];
    [updateProgressIndicator setHidden:YES];
    [contentView addSubview:updateProgressIndicator];

    // --- 3. 手机反控中心 ---
    NSBox* phoneBox = [[NSBox alloc] initWithFrame:NSMakeRect(rightX, 515, rightW, 125)];
    [phoneBox setTitle:@"📱 手机反控中心 (局域网对等直连 / USB 专线)"];
    [phoneBox setTitleFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];

    NSTextField* selectLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 66, 85, 20)];
    [selectLabel setStringValue:@"选择手机:"];
    [selectLabel setFont:[NSFont systemFontOfSize:12]];
    [selectLabel setBezeled:NO];
    [selectLabel setDrawsBackground:NO];
    [selectLabel setEditable:NO];
    [phoneBox addSubview:selectLabel];

    phonePopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(95, 62, 240, 26) pullsDown:NO];
    [phonePopUp addItemWithTitle:@"(正在自动搜寻局域网手机...)"];
    [phoneBox addSubview:phonePopUp];

    connectPhoneBtn = [[NSButton alloc] initWithFrame:NSMakeRect(345, 60, 95, 28)];
    [connectPhoneBtn setTitle:@"连接手机"];
    [connectPhoneBtn setBezelStyle:NSBezelStyleRounded];
    [connectPhoneBtn setTarget:self];
    [connectPhoneBtn setAction:@selector(onConnectPhoneClicked:)];
    [phoneBox addSubview:connectPhoneBtn];

    NSButton* refreshPhoneBtn = [[NSButton alloc] initWithFrame:NSMakeRect(445, 60, 85, 28)];
    [refreshPhoneBtn setTitle:@"刷新搜索"];
    [refreshPhoneBtn setBezelStyle:NSBezelStyleRounded];
    [refreshPhoneBtn setTarget:self];
    [refreshPhoneBtn setAction:@selector(onRefreshPhoneClicked:)];
    [phoneBox addSubview:refreshPhoneBtn];

    phoneStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(535, 65, 130, 20)];
    [phoneStatusLabel setStringValue:@"状态: 未连接"];
    [phoneStatusLabel setFont:[NSFont systemFontOfSize:11]];
    [phoneStatusLabel setTextColor:[NSColor secondaryLabelColor]];
    [phoneStatusLabel setBezeled:NO];
    [phoneStatusLabel setDrawsBackground:NO];
    [phoneStatusLabel setEditable:NO];
    [phoneBox addSubview:phoneStatusLabel];

    // 快捷控制按键栏
    usbStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 18, 300, 24)];
    [usbStatusLabel setStringValue:@"正在侦测连接状态..."];
    [usbStatusLabel setFont:[NSFont systemFontOfSize:11.5]];
    [usbStatusLabel setBezeled:NO];
    [usbStatusLabel setDrawsBackground:NO];
    [usbStatusLabel setEditable:NO];
    [phoneBox addSubview:usbStatusLabel];

    NSButton* backBtn = [[NSButton alloc] initWithFrame:NSMakeRect(335, 15, 105, 28)];
    [backBtn setTitle:@"返回 (Back)"];
    [backBtn setBezelStyle:NSBezelStyleRounded];
    [backBtn setTarget:self];
    [backBtn setAction:@selector(onUsbBackClicked:)];
    [phoneBox addSubview:backBtn];

    NSButton* homeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(445, 15, 105, 28)];
    [homeBtn setTitle:@"桌面 (Home)"];
    [homeBtn setBezelStyle:NSBezelStyleRounded];
    [homeBtn setTarget:self];
    [homeBtn setAction:@selector(onUsbHomeClicked:)];
    [phoneBox addSubview:homeBtn];

    NSButton* recentsBtn = [[NSButton alloc] initWithFrame:NSMakeRect(555, 15, 110, 28)];
    [recentsBtn setTitle:@"任务 (Tasks)"];
    [recentsBtn setBezelStyle:NSBezelStyleRounded];
    [recentsBtn setTarget:self];
    [recentsBtn setAction:@selector(onRecentsClicked:)];
    [phoneBox addSubview:recentsBtn];

    [contentView addSubview:phoneBox];

    // --- 4. 运行状态与事件日志视窗 ---
    NSTextField* logTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX, 475, 200, 20)];
    [logTitle setStringValue:@"📋 运行状态与事件日志"];
    [logTitle setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];
    [logTitle setBezeled:NO];
    [logTitle setDrawsBackground:NO];
    [logTitle setEditable:NO];
    [contentView addSubview:logTitle];

    NSButton* clearLogBtn = [[NSButton alloc] initWithFrame:NSMakeRect(rightX + rightW - 85, 472, 85, 26)];
    [clearLogBtn setTitle:@"清空"];
    [clearLogBtn setBezelStyle:NSBezelStyleRounded];
    [clearLogBtn setTarget:self];
    [clearLogBtn setAction:@selector(onClearLogClicked:)];
    [contentView addSubview:clearLogBtn];

    NSScrollView* logScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(rightX, 20, rightW, 445)];
    [logScrollView setHasVerticalScroller:YES];
    [logScrollView setBorderType:NSBezelBorder];
    [logScrollView setAutoresizingMask:NSViewHeightSizable];

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

    // 绑定实时视频流硬解回调 (由唯一的 screenView 处理解码与渲染，跨窗口无缝迁移不中断)
    ctl.SetVideoCallback([weakSelf](const uint8_t* data, size_t size, bool is_key, int64_t pts) {
        AppDelegate* strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->screenView) return;
        [strongSelf->screenView feedVideoPacket:data size:size isKey:is_key pts:pts];
    });

    ctl.SetFastMirrorCallback([weakSelf](bool connected, std::string address) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            if (connected) {
                [strongSelf->phoneStatusLabel setStringValue:@"🎉 已直连 (<20ms)"];
                [strongSelf->phoneStatusLabel setTextColor:[NSColor systemGreenColor]];
                [strongSelf->connectPhoneBtn setTitle:@"断开连接"];

                // 局域网直连成功后，自动弹出独立的手机控制视窗，并将屏幕控制无缝移入独立视窗
                [strongSelf showStandalonePhoneWindow];
                [strongSelf detachMainScreenControl];
                if (strongSelf->standalonePhoneWindow && !address.empty()) {
                    [strongSelf->standalonePhoneWindow setTitle:[NSString stringWithFormat:@"ACast 手机投屏控制 - %@", SafeStr(address)]];
                }
            } else {
                [strongSelf->phoneStatusLabel setStringValue:@"状态: 未连接"];
                [strongSelf->phoneStatusLabel setTextColor:[NSColor secondaryLabelColor]];
                [strongSelf->connectPhoneBtn setTitle:@"连接手机"];
                [strongSelf restoreMainScreenControl];
                [strongSelf->screenView clearFrame];
            }
        });
    });

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
                [strongSelf->usbStatusLabel setStringValue:@"USB: 未连接设备 (局域网 Wi-Fi 通道正常)"];
            } else {
                NSString* desc = [NSString stringWithFormat:@"USB: 已识别 %@ (%@)",
                                  SafeStr((*pDevs)[0].model), SafeStr((*pDevs)[0].serial)];
                [strongSelf->usbStatusLabel setStringValue:desc];
            }
        });
    });

    ctl.SetUpdateCallback([weakSelf](acast::updater::UpdateInfo info) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            if (info.has_update) {
                NSString* text = [NSString stringWithFormat:@"🎉 发现新版本: %@，点击即可一键原地升级！", SafeStr(info.latest_version)];
                [strongSelf->updateBannerLabel setStringValue:text];
                [strongSelf->updateBannerLabel setHidden:NO];
                [strongSelf->updateButton setHidden:NO];
            } else {
                [strongSelf->updateBannerLabel setHidden:YES];
                [strongSelf->updateButton setHidden:YES];
            }
        });
    });

    // 启动控制器组件初始化
    ctl.Init();
    ctl.RefreshPhones();
}

- (void)reloadDevicePopUp {
    [phonePopUp removeAllItems];

    if (cachedWifiPhones.empty() && cachedUsbDevices.empty()) {
        [phonePopUp addItemWithTitle:@"(未搜到手机，请确认手机已连接 Wi-Fi)"];
        [[phonePopUp itemAtIndex:0] setRepresentedObject:nil];
        return;
    }

    // 1. 添加局域网对等发现的 Wi-Fi 手机
    for (const auto& phone : cachedWifiPhones) {
        NSString* title = [NSString stringWithFormat:@"📱 %@ (%@)", SafeStr(phone.name), SafeStr(phone.ip)];
        [phonePopUp addItemWithTitle:title];
        NSMenuItem* item = [phonePopUp lastItem];
        NSDictionary* dict = @{
            @"type": @"wifi",
            @"ip": SafeStr(phone.ip),
            @"port": @(phone.port > 0 ? phone.port : 19999)
        };
        [item setRepresentedObject:dict];
    }

    // 2. 添加 USB 直连设备
    for (const auto& dev : cachedUsbDevices) {
        NSString* title = [NSString stringWithFormat:@"🔌 USB: %@ (%@)", SafeStr(dev.model), SafeStr(dev.serial)];
        [phonePopUp addItemWithTitle:title];
        NSMenuItem* item = [phonePopUp lastItem];
        NSDictionary* dict = @{
            @"type": @"usb",
            @"serial": SafeStr(dev.serial)
        };
        [item setRepresentedObject:dict];
    }
}

- (void)onConnectPhoneClicked:(id)sender {
    auto& ctl = acast::desktop::DesktopController::GetInstance();
    if (ctl.IsWifiPhoneConnected()) {
        ctl.DisconnectWifiPhone();
        return;
    }

    NSMenuItem* selected = [phonePopUp selectedItem];
    if (!selected) return;

    NSDictionary* dict = [selected representedObject];
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

- (void)onQuickInputSend:(NSTextField*)sender {
    NSString* text = [sender stringValue];
    if (text && [text length] > 0) {
        acast::desktop::DesktopController::GetInstance().SendTextInput([text UTF8String]);
        [sender setStringValue:@""];
    }
}

- (void)onQuickInputBtnClicked:(id)sender {
    if (standaloneQuickInput) {
        [self onQuickInputSend:standaloneQuickInput];
    }
}

- (void)onPopStandaloneWindowClicked:(id)sender {
    if (standalonePhoneWindow && [standalonePhoneWindow isVisible]) {
        [self restoreMainScreenControl];
    } else {
        [self showStandalonePhoneWindow];
        [self detachMainScreenControl];
    }
}

- (void)detachMainScreenControl {
    [screenNavBar setHidden:YES];
    [detachedPlaceholderView setHidden:NO];
    [popScreenBtn setTitle:@"⤓ 收回控制屏幕至主窗口"];

    // 关键架构优化：同一个 screenView 实例直接无缝移入独立视窗，硬解管道零中断、零丢帧、永不卡死
    if (standalonePhoneWindow && screenView) {
        NSView* container = [standalonePhoneWindow contentView];
        [screenView removeFromSuperview];
        NSRect cBounds = [container bounds];
        [screenView setFrame:NSMakeRect(0, 84, cBounds.size.width, std::max((CGFloat)100.0, cBounds.size.height - 84))];
        [screenView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [screenView setHidden:NO];
        [container addSubview:screenView];
        [screenView setNeedsDisplay:YES];
    }
}

- (void)restoreMainScreenControl {
    if (standalonePhoneWindow && [standalonePhoneWindow isVisible]) {
        [standalonePhoneWindow orderOut:nil];
    }
    // 关键架构优化：将 screenView 移回主窗口，硬解管线保持连贯运行
    if (screenView) {
        NSView* contentView = [window contentView];
        [screenView removeFromSuperview];
        [screenView setFrame:NSMakeRect(20, 62, 420, 615)];
        [screenView setAutoresizingMask:NSViewHeightSizable];
        [screenView setHidden:NO];
        [contentView addSubview:screenView];
        [screenView setNeedsDisplay:YES];
    }
    [screenNavBar setHidden:NO];
    [detachedPlaceholderView setHidden:YES];
    [popScreenBtn setTitle:@"⤢ 弹出独立控制屏幕窗口"];
}

- (void)windowWillClose:(NSNotification *)notification {
    if ([notification object] == standalonePhoneWindow) {
        [self restoreMainScreenControl];
    }
}

- (void)showStandalonePhoneWindow {
    if (!standalonePhoneWindow) {
        NSRect frame = NSMakeRect(0, 0, 420, 780);
        NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        standalonePhoneWindow = [[NSWindow alloc] initWithContentRect:frame
                                                            styleMask:style
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
        [standalonePhoneWindow setTitle:@"ACast 手机投屏控制 (独立视窗)"];
        [standalonePhoneWindow setMinSize:NSMakeSize(320, 560)];
        [standalonePhoneWindow center];
        [standalonePhoneWindow setReleasedWhenClosed:NO];
        [standalonePhoneWindow setDelegate:self];

        NSView* container = [standalonePhoneWindow contentView];

        // 底部 84 像素综合控制栏 (快捷中文输入 + 导航三键)
        NSView* navBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 84)];
        [navBar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
        [navBar setWantsLayer:YES];
        navBar.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.10 green:0.11 blue:0.13 alpha:1.0].CGColor;

        // 快捷文本输入框 (支持中文输入法长句输入、粘贴内容，按 Enter 键即刻上屏发送)
        standaloneQuickInput = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 48, 315, 26)];
        [standaloneQuickInput setPlaceholderString:@"在此输入中文/英文或粘贴文本，按回车发送..."];
        [standaloneQuickInput setTarget:self];
        [standaloneQuickInput setAction:@selector(onQuickInputSend:)];
        [standaloneQuickInput setAutoresizingMask:NSViewWidthSizable];
        [navBar addSubview:standaloneQuickInput];

        NSButton* btnSend = [[NSButton alloc] initWithFrame:NSMakeRect(335, 46, 70, 28)];
        [btnSend setTitle:@"发送"];
        [btnSend setBezelStyle:NSBezelStyleRounded];
        [btnSend setTarget:self];
        [btnSend setAction:@selector(onQuickInputBtnClicked:)];
        [btnSend setAutoresizingMask:NSViewMinXMargin];
        [navBar addSubview:btnSend];

        NSButton* btnBack = [[NSButton alloc] initWithFrame:NSMakeRect(15, 8, 115, 32)];
        [btnBack setTitle:@"◀ 返回 (Back)"];
        [btnBack setBezelStyle:NSBezelStyleRounded];
        [btnBack setTarget:self];
        [btnBack setAction:@selector(onUsbBackClicked:)];
        [btnBack setAutoresizingMask:NSViewMaxXMargin];
        [navBar addSubview:btnBack];

        NSButton* btnHome = [[NSButton alloc] initWithFrame:NSMakeRect(152, 8, 115, 32)];
        [btnHome setTitle:@"○ 桌面 (Home)"];
        [btnHome setBezelStyle:NSBezelStyleRounded];
        [btnHome setTarget:self];
        [btnHome setAction:@selector(onUsbHomeClicked:)];
        [btnHome setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin];
        [navBar addSubview:btnHome];

        NSButton* btnRecents = [[NSButton alloc] initWithFrame:NSMakeRect(285, 8, 115, 32)];
        [btnRecents setTitle:@"▢ 任务 (Tasks)"];
        [btnRecents setBezelStyle:NSBezelStyleRounded];
        [btnRecents setTarget:self];
        [btnRecents setAction:@selector(onRecentsClicked:)];
        [btnRecents setAutoresizingMask:NSViewMinXMargin];
        [navBar addSubview:btnRecents];

        [container addSubview:navBar];
    }

    [standalonePhoneWindow makeKeyAndOrderFront:nil];
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
