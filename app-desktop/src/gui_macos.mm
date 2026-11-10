#if defined(__APPLE__)

#import <Cocoa/Cocoa.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <SystemExtensions/SystemExtensions.h>
#import <CoreMediaIO/CMIOHardware.h>

#include "gui_interface.h"
#include "desktop_controller.h"
#include "auto_updater.h"
#include <vector>
#include <string>
#include <memory>
#include <algorithm>
#include <atomic>
#include <thread>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>

// ============================================================================
// VirtualCameraRelay: 极低延迟本地虚拟摄像头中继服务 (提供给 Zoom/FaceTime 扩展)
// ============================================================================

class VirtualCameraRelay {
public:
    static VirtualCameraRelay& GetInstance() {
        static VirtualCameraRelay sInstance;
        return sInstance;
    }

    void StartServer(uint16_t port = 19996) {
        if (is_running_) return;
        is_running_ = true;
        server_thread_ = std::thread([this, port]() {
            int server_fd = socket(AF_INET, SOCK_STREAM, 0);
            if (server_fd < 0) return;

            int opt = 1;
            setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

            sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 127.0.0.1
            addr.sin_port = htons(port);

            if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
                close(server_fd);
                return;
            }

            if (listen(server_fd, 5) < 0) {
                close(server_fd);
                return;
            }

            while (is_running_) {
                int client_fd = accept(server_fd, nullptr, nullptr);
                if (client_fd < 0) break;

                int nodelay = 1;
                setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

                {
                    std::lock_guard<std::mutex> lock(clients_mutex_);
                    client_fds_.push_back(client_fd);
                }
            }
            close(server_fd);
        });
    }

    void SendFrame(CVImageBufferRef imageBuffer) {
        if (!is_running_ || !imageBuffer) return;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            if (client_fds_.empty()) return;
        }

        CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(imageBuffer);
        size_t width = CVPixelBufferGetWidth(imageBuffer);
        size_t height = CVPixelBufferGetHeight(imageBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);

        if (base && width > 0 && height > 0) {
            uint32_t data_len = (uint32_t)(width * height * 4);
            std::vector<uint8_t> packet(16 + data_len);
            uint32_t* header = (uint32_t*)packet.data();
            header[0] = 0x4143414D; // "ACAM"
            header[1] = (uint32_t)width;
            header[2] = (uint32_t)height;
            header[3] = data_len;

            uint8_t* dest = packet.data() + 16;
            size_t srcRow = bytesPerRow;
            size_t destRow = width * 4;
            if (srcRow == destRow) {
                memcpy(dest, base, data_len);
            } else {
                size_t minRow = std::min(srcRow, destRow);
                for (size_t y = 0; y < height; ++y) {
                    memcpy(dest + y * destRow, base + y * srcRow, minRow);
                }
            }

            Broadcast(packet.data(), packet.size());
        }

        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    }

    void Broadcast(const uint8_t* data, size_t size) {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (auto it = client_fds_.begin(); it != client_fds_.end(); ) {
            int fd = *it;
            ssize_t sent = send(fd, data, size, 0);
            if (sent <= 0) {
                close(fd);
                it = client_fds_.erase(it);
            } else {
                ++it;
            }
        }
    }

    bool HasClients() {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        return !client_fds_.empty();
    }

    void StopServer() {
        is_running_ = false;
        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (int fd : client_fds_) {
            close(fd);
        }
        client_fds_.clear();
        if (server_thread_.joinable()) {
            server_thread_.detach();
        }
    }

private:
    std::atomic<bool> is_running_{false};
    std::thread server_thread_;
    std::mutex clients_mutex_;
    std::vector<int> client_fds_;
};

// ============================================================================
// CMIOVirtualCameraBroadcaster: CoreMediaIO 虚拟相机直通广播器
// 无需注册未签名扩展，直连系统已就绪的 CMIO 相机扩展 (如 OBS Virtual Camera 或 ACast)
// ============================================================================

class CMIOVirtualCameraBroadcaster {
public:
    static CMIOVirtualCameraBroadcaster& GetInstance() {
        static CMIOVirtualCameraBroadcaster sInstance;
        return sInstance;
    }

    struct SinkDeviceInfo {
        CMIODeviceID deviceId = 0;
        CMIOStreamID sinkStreamId = 0;
        std::string name;
        std::string uid;
        int targetWidth = 1920;
        int targetHeight = 1080;
    };

    std::vector<SinkDeviceInfo> ScanAvailableSinkDevices() {
        std::vector<SinkDeviceInfo> result;
        CMIOObjectPropertyAddress prop = {
            kCMIOHardwarePropertyDevices,
            kCMIOObjectPropertyScopeGlobal,
            kCMIOObjectPropertyElementMain
        };
        UInt32 dataSize = 0;
        if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &prop, 0, NULL, &dataSize) != noErr || dataSize == 0) {
            return result;
        }
        int count = dataSize / sizeof(CMIOObjectID);
        std::vector<CMIOObjectID> devices(count);
        if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &prop, 0, NULL, dataSize, &dataSize, devices.data()) != noErr) {
            return result;
        }

        for (int i = 0; i < count; i++) {
            CMIOObjectID devId = devices[i];

            CMIOObjectPropertyAddress streamProp = {
                kCMIODevicePropertyStreams,
                kCMIOObjectPropertyScopeGlobal,
                kCMIOObjectPropertyElementMain
            };
            UInt32 streamSize = 0;
            if (CMIOObjectGetPropertyDataSize(devId, &streamProp, 0, NULL, &streamSize) != noErr || streamSize == 0) continue;

            int streamCount = streamSize / sizeof(CMIOStreamID);
            std::vector<CMIOStreamID> streams(streamCount);
            if (CMIOObjectGetPropertyData(devId, &streamProp, 0, NULL, streamSize, &streamSize, streams.data()) != noErr) continue;

            for (CMIOStreamID st : streams) {
                CMIOObjectPropertyAddress dirProp = {
                    kCMIOStreamPropertyDirection,
                    kCMIOObjectPropertyScopeGlobal,
                    kCMIOObjectPropertyElementMain
                };
                UInt32 dir = 999;
                UInt32 ds = sizeof(dir);
                // 注意：在 CoreMediaIO 规范中，0 = Output (Host to Device，即写入到虚拟相机的 Sink Stream)
                // 1 = Input (Device to Host，即应用读取的 Source Stream)
                if (CMIOObjectGetPropertyData(st, &dirProp, 0, NULL, ds, &ds, &dir) == noErr && dir == 0) {
                    SinkDeviceInfo info;
                    info.deviceId = devId;
                    info.sinkStreamId = st;

                    CMIOObjectPropertyAddress nameProp = {
                        kCMIOObjectPropertyName,
                        kCMIOObjectPropertyScopeGlobal,
                        kCMIOObjectPropertyElementMain
                    };
                    CFStringRef nameRef = NULL;
                    UInt32 s = sizeof(nameRef);
                    if (CMIOObjectGetPropertyData(devId, &nameProp, 0, NULL, s, &s, &nameRef) == noErr && nameRef) {
                        info.name = [(__bridge NSString*)nameRef UTF8String];
                        CFRelease(nameRef);
                    }

                    CMIOObjectPropertyAddress uidProp = {
                        kCMIODevicePropertyDeviceUID,
                        kCMIOObjectPropertyScopeGlobal,
                        kCMIOObjectPropertyElementMain
                    };
                    CFStringRef uidRef = NULL;
                    s = sizeof(uidRef);
                    if (CMIOObjectGetPropertyData(devId, &uidProp, 0, NULL, s, &s, &uidRef) == noErr && uidRef) {
                        info.uid = [(__bridge NSString*)uidRef UTF8String];
                        CFRelease(uidRef);
                    }

                    CMIOObjectPropertyAddress fmtProp = {
                        kCMIOStreamPropertyFormatDescriptions,
                        kCMIOObjectPropertyScopeGlobal,
                        kCMIOObjectPropertyElementMain
                    };
                    UInt32 fmtSize = 0;
                    if (CMIOObjectGetPropertyDataSize(st, &fmtProp, 0, NULL, &fmtSize) == noErr && fmtSize > 0) {
                        CFArrayRef descs = NULL;
                        if (CMIOObjectGetPropertyData(st, &fmtProp, 0, NULL, fmtSize, &fmtSize, &descs) == noErr && descs) {
                            if (CFArrayGetCount(descs) > 0) {
                                CMFormatDescriptionRef fd = (CMFormatDescriptionRef)CFArrayGetValueAtIndex(descs, 0);
                                CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fd);
                                if (dim.width > 0 && dim.height > 0) {
                                    info.targetWidth = dim.width;
                                    info.targetHeight = dim.height;
                                }
                            }
                            CFRelease(descs);
                        }
                    }

                    result.push_back(info);
                }
            }
        }
        return result;
    }

    void StartBroadcaster() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ConnectSinkLocked();
        }
        if (pump_running_.exchange(true)) return;
        pump_thread_ = std::thread([this]() {
            int retry_ticks = 0;
            while (pump_running_.load()) {
                usleep(33000); // 30 FPS 保活节拍
                if (!pump_running_.load()) break;

                std::lock_guard<std::mutex> lock(mutex_);
                if (!is_connected_ || !queue_) {
                    if (++retry_ticks >= 60) { // 每 2 秒自动尝试探测并接入系统相机扩展
                        retry_ticks = 0;
                        ConnectSinkLocked();
                    }
                    continue;
                }

                auto now = std::chrono::steady_clock::now();
                auto sinceLastPushMs = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_push_time_).count();
                if (sinceLastPushMs < 40) {
                    // 实时视频流正在高频推送中，无需保活线程重复插帧
                    continue;
                }

                CVPixelBufferRef bufToPush = NULL;
                if (latest_live_buffer_) {
                    auto sinceLiveSec = std::chrono::duration_cast<std::chrono::seconds>(now - last_live_frame_time_).count();
                    if (sinceLiveSec < 15) {
                        bufToPush = latest_live_buffer_;
                    } else {
                        CVPixelBufferRelease(latest_live_buffer_);
                        latest_live_buffer_ = NULL;
                    }
                }
                if (!bufToPush) {
                    if (!standby_buffer_) {
                        standby_buffer_ = CreateStandbyPixelBufferLocked(
                            active_device_.targetWidth > 0 ? active_device_.targetWidth : 1920,
                            active_device_.targetHeight > 0 ? active_device_.targetHeight : 1080);
                    }
                    bufToPush = standby_buffer_;
                }

                if (bufToPush) {
                    PushPixelBufferToQueueLocked(bufToPush);
                }
            }
        });
    }

    bool ConnectSink() {
        std::lock_guard<std::mutex> lock(mutex_);
        return ConnectSinkLocked();
    }

    void ClearLiveFrame() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (latest_live_buffer_) {
            CVPixelBufferRelease(latest_live_buffer_);
            latest_live_buffer_ = NULL;
        }
    }

    void SendFrame(CVImageBufferRef imageBuffer) {
        if (!imageBuffer) return;

        std::lock_guard<std::mutex> lock(mutex_);
        if (!is_connected_) {
            if (!ConnectSinkLocked()) return;
        }

        if (!queue_ || !target_pool_ || !transfer_session_) return;

        size_t srcW = CVPixelBufferGetWidth(imageBuffer);
        size_t srcH = CVPixelBufferGetHeight(imageBuffer);
        if (srcW == 0 || srcH == 0) return;

        int targetW = active_device_.targetWidth > 0 ? active_device_.targetWidth : 1920;
        int targetH = active_device_.targetHeight > 0 ? active_device_.targetHeight : 1080;

        // 必须始终从包含 kCVPixelBufferIOSurfacePropertiesKey 的 target_pool_ 分配缓冲，
        // 否则 CoreMediaIO 跨进程 XPC 传输至 cmioextension 守护进程时会因无 IOSurface 映射而黑屏！
        CVPixelBufferRef iosurfaceBuffer = NULL;
        CVReturn cvRet = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, target_pool_, &iosurfaceBuffer);
        if (cvRet != kCVReturnSuccess || !iosurfaceBuffer) {
            return;
        }

        // 若源图像宽高比与目标不同（例如竖屏手机投屏画面进入 16:9 虚拟摄像头），先清空背景为纯黑以配合 Letterbox 等比缩放
        if (srcW * (size_t)targetH != srcH * (size_t)targetW) {
            CVPixelBufferLockBaseAddress(iosurfaceBuffer, 0);
            void* base = CVPixelBufferGetBaseAddress(iosurfaceBuffer);
            size_t bpr = CVPixelBufferGetBytesPerRow(iosurfaceBuffer);
            if (base && bpr > 0) {
                memset(base, 0, bpr * (size_t)targetH);
            }
            CVPixelBufferUnlockBaseAddress(iosurfaceBuffer, 0);
        }

        OSStatus trErr = VTPixelTransferSessionTransferImage(transfer_session_, imageBuffer, iosurfaceBuffer);
        if (trErr != noErr) {
            CVPixelBufferRelease(iosurfaceBuffer);
            return;
        }

        if (latest_live_buffer_) {
            CVPixelBufferRelease(latest_live_buffer_);
        }
        latest_live_buffer_ = CVPixelBufferRetain(iosurfaceBuffer);
        last_live_frame_time_ = std::chrono::steady_clock::now();
        last_push_time_ = last_live_frame_time_;
        live_frames_++;

        PushPixelBufferToQueueLocked(iosurfaceBuffer);
        CVPixelBufferRelease(iosurfaceBuffer);
    }

    bool HasActiveSink() {
        std::lock_guard<std::mutex> lock(mutex_);
        return is_connected_;
    }

    std::string GetActiveSinkName() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (is_connected_) return active_device_.name;
        return "";
    }

    uint64_t GetSentFrames() const {
        return sent_frames_.load();
    }

    uint64_t GetLiveFrames() const {
        return live_frames_.load();
    }

    void Disconnect() {
        pump_running_ = false;
        if (pump_thread_.joinable()) {
            pump_thread_.join();
        }
        std::lock_guard<std::mutex> lock(mutex_);
        if (latest_live_buffer_) {
            CVPixelBufferRelease(latest_live_buffer_);
            latest_live_buffer_ = NULL;
        }
        if (standby_buffer_) {
            CVPixelBufferRelease(standby_buffer_);
            standby_buffer_ = NULL;
        }
        if (is_connected_) {
            if (active_device_.deviceId && active_device_.sinkStreamId) {
                CMIODeviceStopStream(active_device_.deviceId, active_device_.sinkStreamId);
            }
            if (queue_) {
                CFRelease(queue_);
                queue_ = NULL;
            }
            if (transfer_session_) {
                VTPixelTransferSessionInvalidate(transfer_session_);
                CFRelease(transfer_session_);
                transfer_session_ = NULL;
            }
            if (target_pool_) {
                CVPixelBufferPoolRelease(target_pool_);
                target_pool_ = NULL;
            }
            is_connected_ = false;
        }
    }

    ~CMIOVirtualCameraBroadcaster() {
        Disconnect();
    }

private:
    static void DummyQueueAltered(CMIOStreamID streamID, void* token, void* refCon) {}

    void PushPixelBufferToQueueLocked(CVPixelBufferRef bufferToSend) {
        if (!queue_ || !bufferToSend) return;

        CMVideoFormatDescriptionRef formatDesc = NULL;
        OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, bufferToSend, &formatDesc);
        if (st == noErr && formatDesc) {
            CMSampleTimingInfo timing = kCMTimingInfoInvalid;
            timing.duration = CMTimeMake(1, 30);
            timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());

            CMSampleBufferRef sbuf = NULL;
            st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, bufferToSend, formatDesc, &timing, &sbuf);
            if (st == noErr && sbuf) {
                // 严格遵循 CoreMediaIO 单生产者/单消费者队列契约（与 OBS mac-virtualcam 一致）：
                // 仅在队列未满时 Enqueue，绝不在生产端调用 Dequeue 破坏消费端指针
                if (CMSimpleQueueGetCount(queue_) < CMSimpleQueueGetCapacity(queue_)) {
                    OSStatus qErr = CMSimpleQueueEnqueue(queue_, sbuf);
                    if (qErr == noErr) {
                        sent_frames_++;
                        full_queue_streak_ = 0;
                    } else {
                        CFRelease(sbuf);
                    }
                } else {
                    CFRelease(sbuf);
                    if (++full_queue_streak_ >= 60) {
                        full_queue_streak_ = 0;
                        CMIODeviceStartStream(active_device_.deviceId, active_device_.sinkStreamId);
                    }
                }
            }
            CFRelease(formatDesc);
        }
    }

    CVPixelBufferRef CreateStandbyPixelBufferLocked(int width, int height) {
        if (!target_pool_) return NULL;
        CVPixelBufferRef pb = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, target_pool_, &pb) != kCVReturnSuccess || !pb) {
            return NULL;
        }

        CVPixelBufferLockBaseAddress(pb, 0);
        void* base = CVPixelBufferGetBaseAddress(pb);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        uint32_t bitmapInfo = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;

        CGContextRef ctx = CGBitmapContextCreate(base, width, height, 8, bytesPerRow, colorSpace, bitmapInfo);
        if (ctx) {
            CGFloat w = (CGFloat)width;
            CGFloat h = (CGFloat)height;

            // 深色背景
            CGContextSetRGBFillColor(ctx, 0.07, 0.09, 0.14, 1.0);
            CGContextFillRect(ctx, CGRectMake(0, 0, w, h));

            // 中心卡片
            CGFloat cardW = 920;
            CGFloat cardH = 320;
            CGRect cardRect = CGRectMake((w - cardW) * 0.5, (h - cardH) * 0.5, cardW, cardH);
            CGPathRef cardPath = CGPathCreateWithRoundedRect(cardRect, 24, 24, NULL);
            CGContextSetRGBFillColor(ctx, 0.12, 0.15, 0.22, 0.96);
            CGContextAddPath(ctx, cardPath);
            CGContextFillPath(ctx);

            CGContextSetRGBStrokeColor(ctx, 0.25, 0.52, 0.96, 0.85);
            CGContextSetLineWidth(ctx, 3.0);
            CGContextAddPath(ctx, cardPath);
            CGContextStrokePath(ctx);
            CGPathRelease(cardPath);

            // 使用 NSGraphicsContext 绘制清晰文字说明
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext* nsCtx = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
            [NSGraphicsContext setCurrentContext:nsCtx];

            NSMutableParagraphStyle* pStyle = [[NSMutableParagraphStyle alloc] init];
            [pStyle setAlignment:NSTextAlignmentCenter];

            NSDictionary* titleAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:40 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: [NSColor whiteColor],
                NSParagraphStyleAttributeName: pStyle
            };
            [@"ACast 虚拟摄像头已就绪 (1080P 30FPS)" drawInRect:NSMakeRect(cardRect.origin.x + 30, cardRect.origin.y + 185, cardW - 60, 60) withAttributes:titleAttrs];

            NSDictionary* subAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:24 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.65 green:0.78 blue:0.98 alpha:1.0],
                NSParagraphStyleAttributeName: pStyle
            };
            [@"请在手机端开启【摄像头推流】或【屏幕共享】\n画面将实时直通至 Zoom / FaceTime / 腾讯会议" drawInRect:NSMakeRect(cardRect.origin.x + 30, cardRect.origin.y + 70, cardW - 60, 90) withAttributes:subAttrs];

            [NSGraphicsContext restoreGraphicsState];
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(colorSpace);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        return pb;
    }

    bool ConnectSinkLocked() {
        if (is_connected_ && queue_) return true;

        auto devices = ScanAvailableSinkDevices();
        if (devices.empty()) return false;

        SinkDeviceInfo selected = devices[0];
        for (const auto& d : devices) {
            if (d.name.find("ACast") != std::string::npos) {
                selected = d;
                break;
            } else if (d.name.find("OBS") != std::string::npos) {
                selected = d;
            }
        }

        active_device_ = selected;

        CMSimpleQueueRef queue = NULL;
        OSStatus err = CMIOStreamCopyBufferQueue(active_device_.sinkStreamId, DummyQueueAltered, NULL, &queue);
        if (err != noErr || !queue) {
            return false;
        }

        CMIODeviceStartStream(active_device_.deviceId, active_device_.sinkStreamId);

        queue_ = queue;
        is_connected_ = true;
        full_queue_streak_ = 0;
        last_push_time_ = std::chrono::steady_clock::now() - std::chrono::seconds(1);

        int w = active_device_.targetWidth > 0 ? active_device_.targetWidth : 1920;
        int h = active_device_.targetHeight > 0 ? active_device_.targetHeight : 1080;
        InitTargetPool(w, h);

        if (standby_buffer_) {
            CVPixelBufferRelease(standby_buffer_);
        }
        standby_buffer_ = CreateStandbyPixelBufferLocked(w, h);
        if (standby_buffer_) {
            PushPixelBufferToQueueLocked(standby_buffer_);
        }
        return true;
    }

    void InitTargetPool(int width, int height) {
        if (target_pool_) {
            CVPixelBufferPoolRelease(target_pool_);
            target_pool_ = NULL;
        }
        if (transfer_session_) {
            VTPixelTransferSessionInvalidate(transfer_session_);
            CFRelease(transfer_session_);
            transfer_session_ = NULL;
        }

        VTPixelTransferSessionCreate(kCFAllocatorDefault, &transfer_session_);
        if (transfer_session_) {
            VTSessionSetProperty(transfer_session_, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Letterbox);
        }

        // 关键：必须包含 kCVPixelBufferIOSurfacePropertiesKey，否则跨进程 CMIO XPC 队列无法共享显存页面
        NSDictionary* pixelAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
        };
        NSDictionary* poolAttrs = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @15
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttrs, (__bridge CFDictionaryRef)pixelAttrs, &target_pool_);
    }

    std::mutex mutex_;
    bool is_connected_ = false;
    SinkDeviceInfo active_device_;
    CMSimpleQueueRef queue_ = NULL;
    VTPixelTransferSessionRef transfer_session_ = NULL;
    CVPixelBufferPoolRef target_pool_ = NULL;
    CVPixelBufferRef latest_live_buffer_ = NULL;
    CVPixelBufferRef standby_buffer_ = NULL;
    std::chrono::steady_clock::time_point last_live_frame_time_;
    std::chrono::steady_clock::time_point last_push_time_;
    int full_queue_streak_ = 0;
    std::atomic<bool> pump_running_{false};
    std::thread pump_thread_;
    std::atomic<uint64_t> sent_frames_{0};
    std::atomic<uint64_t> live_frames_{0};
};

static NSString* SafeStr(const std::string& str) {
    if (str.empty()) return @"";
    NSString* ns = [NSString stringWithUTF8String:str.c_str()];
    if (!ns) {
        ns = [[NSString alloc] initWithBytes:str.data() length:str.size() encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    return ns;
}

// ============================================================================
// CameraStreamDecoder: 专用的 Android 摄像头硬件流解码器 (与屏幕投屏解码管线彻底解耦)
// 支持屏幕投屏与手机虚拟摄像头双流并发、互不抢占、互不关闭！
// ============================================================================

static void CameraDecompressCallback(void* decompressionOutputRefCon,
                                     void* sourceFrameRefCon,
                                     OSStatus status,
                                     VTDecodeInfoFlags infoFlags,
                                     CVImageBufferRef imageBuffer,
                                     CMTime presentationTimeStamp,
                                     CMTime presentationDuration) {
    if (status == noErr && imageBuffer != NULL) {
        // 摄像头独立流：直接分发给虚拟相机直通与本地中继
        VirtualCameraRelay::GetInstance().SendFrame(imageBuffer);
        CMIOVirtualCameraBroadcaster::GetInstance().SendFrame(imageBuffer);
    }
}

class CameraStreamDecoder {
public:
    static CameraStreamDecoder& GetInstance() {
        static CameraStreamDecoder sInstance;
        return sInstance;
    }

    void FeedPacket(const uint8_t* data, size_t size, bool isKey, int64_t pts) {
        if (!data || size < 4) return;
        last_camera_frame_time_ = std::chrono::steady_clock::now();
        has_active_camera_stream_ = true;

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
                if (sps_data_.size() != nal.size || memcmp(sps_data_.data(), nal.ptr, nal.size) != 0) {
                    sps_data_.assign(nal.ptr, nal.ptr + nal.size);
                    hasNewParams = true;
                }
            } else if (nal.type == 8) { // PPS
                if (pps_data_.size() != nal.size || memcmp(pps_data_.data(), nal.ptr, nal.size) != 0) {
                    pps_data_.assign(nal.ptr, nal.ptr + nal.size);
                    hasNewParams = true;
                }
            }
        }

        if ((hasNewParams || decompression_session_ == NULL || format_description_ == NULL) && !sps_data_.empty() && !pps_data_.empty()) {
            if (decompression_session_) {
                VTDecompressionSessionInvalidate(decompression_session_);
                CFRelease(decompression_session_);
                decompression_session_ = NULL;
            }
            if (format_description_) {
                CFRelease(format_description_);
                format_description_ = NULL;
            }

            const uint8_t* parameterSetPointers[2] = { sps_data_.data(), pps_data_.data() };
            const size_t parameterSetSizes[2] = { sps_data_.size(), pps_data_.size() };

            OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4, &format_description_);

            if (status == noErr && format_description_) {
                VTDecompressionOutputCallbackRecord cbRecord;
                cbRecord.decompressionOutputCallback = CameraDecompressCallback;
                cbRecord.decompressionOutputRefCon = this;

                NSDictionary* destinationImageBufferAttributes = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                    (id)kCVPixelBufferMetalCompatibilityKey: @(YES),
                    (id)kCVPixelBufferOpenGLCompatibilityKey: @(YES)
                };

                status = VTDecompressionSessionCreate(
                    kCFAllocatorDefault, format_description_, NULL,
                    (__bridge CFDictionaryRef)destinationImageBufferAttributes,
                    &cbRecord, &decompression_session_);

                if (status == noErr && decompression_session_) {
                    VTSessionSetProperty(decompression_session_, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
                }
            }
        }

        std::vector<NalUnit> slices;
        for (const auto& nal : nals) {
            if (nal.type == 1 || nal.type == 5) {
                slices.push_back(nal);
            }
        }

        if (!slices.empty() && decompression_session_ && format_description_) {
            size_t totalAvccLen = 0;
            for (const auto& s : slices) totalAvccLen += 4 + s.size;
            uint8_t* avcc = (uint8_t*)malloc(totalAvccLen);
            if (!avcc) return;

            size_t offset = 0;
            for (const auto& s : slices) {
                uint32_t sLen = htonl((uint32_t)s.size);
                memcpy(avcc + offset, &sLen, 4);
                memcpy(avcc + offset + 4, s.ptr, s.size);
                offset += 4 + s.size;
            }

            CMBlockBufferRef blockBuffer = NULL;
            OSStatus status = CMBlockBufferCreateWithMemoryBlock(
                kCFAllocatorDefault, avcc, totalAvccLen, kCFAllocatorMalloc, NULL, 0, totalAvccLen, 0, &blockBuffer);

            if (status == noErr && blockBuffer) {
                CMSampleBufferRef sampleBuffer = NULL;
                CMSampleTimingInfo timingInfo;
                timingInfo.duration = kCMTimeInvalid;
                timingInfo.presentationTimeStamp = (pts > 0) ? CMTimeMake(pts, 1000000) : kCMTimeInvalid;
                timingInfo.decodeTimeStamp = kCMTimeInvalid;

                status = CMSampleBufferCreateReady(
                    kCFAllocatorDefault, blockBuffer, format_description_, 1, 1, &timingInfo, 0, NULL, &sampleBuffer);

                if (status == noErr && sampleBuffer) {
                    VTDecodeFrameFlags decodeFlags = kVTDecodeFrame_EnableAsynchronousDecompression;
                    VTDecodeInfoFlags flagOut;
                    VTDecompressionSessionDecodeFrame(decompression_session_, sampleBuffer, decodeFlags, NULL, &flagOut);
                    CFRelease(sampleBuffer);
                }
                CFRelease(blockBuffer);
            } else {
                free(avcc);
            }
        }
    }

    bool HasActiveCameraStream() {
        if (!has_active_camera_stream_) return false;
        auto now = std::chrono::steady_clock::now();
        auto diff = std::chrono::duration_cast<std::chrono::seconds>(now - last_camera_frame_time_).count();
        if (diff > 3) {
            has_active_camera_stream_ = false;
        }
        return has_active_camera_stream_;
    }

private:
    VTDecompressionSessionRef decompression_session_{NULL};
    CMVideoFormatDescriptionRef format_description_{NULL};
    std::vector<uint8_t> sps_data_;
    std::vector<uint8_t> pps_data_;
    std::atomic<bool> has_active_camera_stream_{false};
    std::chrono::steady_clock::time_point last_camera_frame_time_;
};

@class ScreenMirrorView;

// ============================================================================
// 悬浮式极简导航胶囊栏按键 (纯图标、高对比度微交互)
// ============================================================================
@interface FloatingNavButton : NSButton {
    NSTrackingArea* _trackingArea;
}
@end

// ============================================================================
// 屏中悬浮导航栏容器 (毛玻璃深色胶囊 HUD，带平滑阴影与防穿透保护)
// ============================================================================
@interface FloatingNavBarView : NSView {
    NSTrackingArea* _navBarTrackingArea;
}
@property (nonatomic, weak) ScreenMirrorView* mirrorView;
@end

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
    bool isMouseDown;
    uint16_t lastSentNormX;
    uint16_t lastSentNormY;

    NSMutableAttributedString* markedString;
    NSRange markedRange;
    NSRange selectedRange;

    FloatingNavBarView* floatingNavBar;
    FloatingNavButton* floatingBackBtn;
    FloatingNavButton* floatingHomeBtn;
    FloatingNavButton* floatingRecentsBtn;
    NSTrackingArea* mirrorTrackingArea;
    NSTimer* navBarAutoHideTimer;
}

- (void)feedVideoPacket:(const uint8_t*)data size:(size_t)size isKey:(bool)isKey pts:(int64_t)pts;
- (void)deliverDecodedImage:(CGImageRef)image;
- (void)handleDecodeError:(OSStatus)status;
- (void)clearFrame;

- (void)keepFloatingNavBarVisible;
- (void)showFloatingNavBarAnimated;
- (void)hideFloatingNavBarAnimated;
- (void)hideFloatingNavBarImmediately;
- (void)updateFloatingNavBarPosition;

@end

@implementation FloatingNavButton

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setButtonType:NSButtonTypeMomentaryChange];
        [self setBordered:NO];
        [self setWantsLayer:YES];
        self.layer.cornerRadius = 15.0;
        self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.12].CGColor;
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds]
                                                 options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.28].CGColor;
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.12].CGColor;
}

- (void)mouseDown:(NSEvent *)event {
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.42].CGColor;
    [super mouseDown:event];
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.28].CGColor;
}

@end

@implementation FloatingNavBarView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setWantsLayer:YES];
        self.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.08 green:0.09 blue:0.12 alpha:0.88].CGColor;
        self.layer.cornerRadius = 19.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.20].CGColor;
        self.layer.shadowColor = [NSColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.45;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0, -2);
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_navBarTrackingArea) {
        [self removeTrackingArea:_navBarTrackingArea];
    }
    _navBarTrackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds]
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil];
    [self addTrackingArea:_navBarTrackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    if (self.mirrorView) {
        [self.mirrorView keepFloatingNavBarVisible];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    [super mouseMoved:event];
    if (self.mirrorView) {
        [self.mirrorView keepFloatingNavBarVisible];
    }
}

- (void)mouseDown:(NSEvent *)event {
    // 拦截空白区域点击，避免误触底层手机投屏
}

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
        // 若当前未激活独立摄像头流，则将屏幕投屏流同步至虚拟相机作为画面源
        if (!CameraStreamDecoder::GetInstance().HasActiveCameraStream()) {
            if (VirtualCameraRelay::GetInstance().HasClients()) {
                VirtualCameraRelay::GetInstance().SendFrame(imageBuffer);
            }
            CMIOVirtualCameraBroadcaster::GetInstance().SendFrame(imageBuffer);
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
        isMouseDown = false;
        lastSentNormX = 5000;
        lastSentNormY = 5000;
        markedString = nil;
        markedRange = NSMakeRange(NSNotFound, 0);
        selectedRange = NSMakeRange(0, 0);

        mirrorTrackingArea = nil;
        navBarAutoHideTimer = nil;

        // 屏中悬浮导航胶囊栏：纯图标无文字，初始透明隐藏，鼠标移到底部时平滑悬浮浮现
        CGFloat barW = 168.0;
        CGFloat barH = 38.0;
        floatingNavBar = [[FloatingNavBarView alloc] initWithFrame:NSMakeRect((frameRect.size.width - barW) * 0.5, 16.0, barW, barH)];
        floatingNavBar.mirrorView = self;
        [floatingNavBar setAlphaValue:0.0];
        [floatingNavBar setHidden:YES];

        auto createNavBtn = ^(NSRect frame, NSString* icon, NSString* tooltip, SEL action) {
            FloatingNavButton* btn = [[FloatingNavButton alloc] initWithFrame:frame];
            [btn setTarget:self];
            [btn setAction:action];
            [btn setToolTip:tooltip];

            NSMutableParagraphStyle* pStyle = [[NSMutableParagraphStyle alloc] init];
            [pStyle setAlignment:NSTextAlignmentCenter];
            NSAttributedString* attr = [[NSAttributedString alloc] initWithString:icon attributes:@{
                NSForegroundColorAttributeName: [NSColor whiteColor],
                NSFontAttributeName: [NSFont systemFontOfSize:17.0 weight:NSFontWeightMedium],
                NSParagraphStyleAttributeName: pStyle
            }];
            [btn setAttributedTitle:attr];
            return btn;
        };

        floatingBackBtn = createNavBtn(NSMakeRect(12, 4, 42, 30), @"◀", @"返回 (Back)", @selector(onFloatingBackClicked:));
        [floatingNavBar addSubview:floatingBackBtn];

        floatingHomeBtn = createNavBtn(NSMakeRect(63, 4, 42, 30), @"○", @"桌面 (Home)", @selector(onFloatingHomeClicked:));
        [floatingNavBar addSubview:floatingHomeBtn];

        floatingRecentsBtn = createNavBtn(NSMakeRect(114, 4, 42, 30), @"▢", @"任务 (Tasks)", @selector(onFloatingRecentsClicked:));
        [floatingNavBar addSubview:floatingRecentsBtn];

        [self addSubview:floatingNavBar];
    }
    return self;
}

- (void)dealloc {
    if (navBarAutoHideTimer) {
        [navBarAutoHideTimer invalidate];
        navBarAutoHideTimer = nil;
    }
    if (mirrorTrackingArea) {
        [self removeTrackingArea:mirrorTrackingArea];
        mirrorTrackingArea = nil;
    }
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

    NSString* guide = @"等待手机连接推流中...\n\n在手机 ACast 点击【开启投屏】\n画面将在此实时呈现\n\n🖱️ 鼠标点击与拖拽滑动模拟触控\n⌨️ 电脑键盘直接输入文字与按键\n🖱️ 鼠标右键或 ESC 触发【返回】\n⬇️ 鼠标移至底部悬浮呼出导航键 (◀ ○ ▢)";
    [guide drawInRect:NSMakeRect(20, bounds.size.height * 0.5 - 110, bounds.size.width - 40, 140) withAttributes:subAttr];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)mouseDown:(NSEvent *)initialEvent {
    [[self window] makeFirstResponder:self];
    [self hideFloatingNavBarImmediately];
    isMouseDown = true;
    lastDragSendTime = std::chrono::steady_clock::now();
    [self sendNormalizedTouchWithEvent:initialEvent action:0]; // 0: DOWN (100% 立即发送)

    // 采用 AppKit 标准 Mouse Tracking Loop 机制：
    // 无论是大幅度快速甩出视窗、甩到 Dock 栏或桌面任何角落，
    // 整个拖拽轨迹与最终的松手抬起 (mouseUp) 都能 100% 精确捕获，绝不发生滑出视窗后卡住悬按！
    NSWindow* win = [self window];
    if (!win) return;

    BOOL keepTracking = YES;
    while (keepTracking) {
        @autoreleasepool {
            NSEvent* event = [win nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
            if (!event) break;

            if ([event type] == NSEventTypeLeftMouseDragged) {
                // 安全防卫：如果底层检测到鼠标按键已释放
                if (([NSEvent pressedMouseButtons] & 1) == 0) {
                    [self sendNormalizedTouchWithEvent:event action:2]; // UP
                    isMouseDown = false;
                    keepTracking = NO;
                    break;
                }

                auto now = std::chrono::steady_clock::now();
                auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastDragSendTime).count();
                if (elapsed >= 15) { // 限制最低发送间隔约 60Hz，保证流畅且防背压
                    lastDragSendTime = now;
                    [self sendNormalizedTouchWithEvent:event action:1]; // 1: MOVE
                }
            } else if ([event type] == NSEventTypeLeftMouseUp) {
                [self sendNormalizedTouchWithEvent:event action:2]; // 2: UP (100% 准确抬手)
                isMouseDown = false;
                keepTracking = NO;
                break;
            }
        }
    }
}

- (void)mouseDragged:(NSEvent *)event {
    // 备用事件路径
    if (([NSEvent pressedMouseButtons] & 1) == 0) {
        if (isMouseDown) {
            [self mouseUp:event];
        }
        return;
    }

    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastDragSendTime).count();
    if (elapsed < 15) {
        return;
    }
    lastDragSendTime = now;
    [self sendNormalizedTouchWithEvent:event action:1];
}

- (void)mouseUp:(NSEvent *)event {
    isMouseDown = false;
    [self sendNormalizedTouchWithEvent:event action:2];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    if (newWindow) {
        [newWindow setAcceptsMouseMovedEvents:YES];
    }
    if (!newWindow && isMouseDown) {
        [self safetyReleaseTouch];
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (mirrorTrackingArea) {
        [self removeTrackingArea:mirrorTrackingArea];
    }
    NSTrackingAreaOptions options = NSTrackingMouseMoved |
                                   NSTrackingMouseEnteredAndExited |
                                   NSTrackingActiveAlways |
                                   NSTrackingInVisibleRect;
    mirrorTrackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds]
                                                      options:options
                                                        owner:self
                                                     userInfo:nil];
    [self addTrackingArea:mirrorTrackingArea];
}

- (void)mouseMoved:(NSEvent *)event {
    if (isMouseDown) return;

    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    CGFloat bottomY = (lastAspectFitRect.size.height > 0) ? lastAspectFitRect.origin.y : 0;
    CGFloat triggerThreshold = bottomY + 80.0;

    // 鼠标向下移动到一定位置时，在屏中平滑悬浮显示虚拟按键胶囊栏
    if (loc.y >= bottomY && loc.y <= triggerThreshold && loc.x >= 0 && loc.x <= self.bounds.size.width) {
        [self showFloatingNavBarAnimated];
    } else {
        NSPoint locInBar = [floatingNavBar convertPoint:[event locationInWindow] fromView:nil];
        if (![floatingNavBar mouse:locInBar inRect:[floatingNavBar bounds]]) {
            [self hideFloatingNavBarAnimated];
        }
    }
}

- (void)mouseExited:(NSEvent *)event {
    [self hideFloatingNavBarAnimated];
}

- (void)keepFloatingNavBarVisible {
    if (navBarAutoHideTimer) {
        [navBarAutoHideTimer invalidate];
        navBarAutoHideTimer = nil;
    }
    if (floatingNavBar.isHidden || floatingNavBar.alphaValue < 0.99) {
        [floatingNavBar setHidden:NO];
        floatingNavBar.alphaValue = 1.0;
    }
}

- (void)showFloatingNavBarAnimated {
    if (!floatingNavBar) return;
    [self updateFloatingNavBarPosition];

    if (floatingNavBar.isHidden || floatingNavBar.alphaValue < 0.99) {
        [floatingNavBar setHidden:NO];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
            context.duration = 0.2;
            floatingNavBar.animator.alphaValue = 1.0;
        }];
    }

    if (navBarAutoHideTimer) {
        [navBarAutoHideTimer invalidate];
        navBarAutoHideTimer = nil;
    }
    __weak typeof(self) weakSelf = self;
    navBarAutoHideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        [weakSelf hideFloatingNavBarAnimated];
    }];
}

- (void)hideFloatingNavBarAnimated {
    if (!floatingNavBar || floatingNavBar.isHidden || floatingNavBar.alphaValue <= 0.01) return;
    if (navBarAutoHideTimer) {
        [navBarAutoHideTimer invalidate];
        navBarAutoHideTimer = nil;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.25;
        floatingNavBar.animator.alphaValue = 0.0;
    } completionHandler:^{
        if (floatingNavBar.alphaValue <= 0.01) {
            [floatingNavBar setHidden:YES];
        }
    }];
}

- (void)hideFloatingNavBarImmediately {
    if (!floatingNavBar) return;
    if (navBarAutoHideTimer) {
        [navBarAutoHideTimer invalidate];
        navBarAutoHideTimer = nil;
    }
    [floatingNavBar setAlphaValue:0.0];
    [floatingNavBar setHidden:YES];
}

- (void)layout {
    [super layout];
    [self updateFloatingNavBarPosition];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self updateFloatingNavBarPosition];
}

- (void)updateFloatingNavBarPosition {
    if (!floatingNavBar) return;
    CGFloat barW = 168.0;
    CGFloat barH = 38.0;
    CGFloat barX = (self.bounds.size.width - barW) * 0.5;
    CGFloat bottomY = (lastAspectFitRect.size.height > 0) ? lastAspectFitRect.origin.y : 0;
    CGFloat barY = std::max((CGFloat)16.0, bottomY + 16.0);
    [floatingNavBar setFrame:NSMakeRect(barX, barY, barW, barH)];
}

- (void)onFloatingBackClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().SendBackKey();
}

- (void)onFloatingHomeClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().SendHomeKey();
}

- (void)onFloatingRecentsClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().SendRecentsKey();
}

- (BOOL)resignFirstResponder {
    if (isMouseDown) {
        [self safetyReleaseTouch];
    }
    return [super resignFirstResponder];
}

- (void)safetyReleaseTouch {
    if (isMouseDown) {
        isMouseDown = false;
        acast::desktop::DesktopController::GetInstance().SendTouch(2, lastSentNormX, lastSentNormY);
    }
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

    lastSentNormX = nx;
    lastSentNormY = ny;

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
    } else if (code == 122) { // F1 -> 下拉展开系统通知栏
        ctl.SendKey(5);
        return;
    } else if (code == 120) { // F2 -> 下拉展开快捷设置控制中心
        ctl.SendKey(6);
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

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, OSSystemExtensionRequestDelegate> {
    NSWindow* window;
    ScreenMirrorView* screenView;
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
    NSTextField* cameraStatusLabel;
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
    [window setAcceptsMouseMovedEvents:YES];

    NSView* contentView = [window contentView];

    // ==================== 左侧：手机实时投屏与控制视窗 ====================
    popScreenBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 685, 420, 28)];
    [popScreenBtn setTitle:@"⤢ 弹出独立控制屏幕窗口"];
    [popScreenBtn setBezelStyle:NSBezelStyleRounded];
    [popScreenBtn setTarget:self];
    [popScreenBtn setAction:@selector(onPopStandaloneWindowClicked:)];
    [contentView addSubview:popScreenBtn];

    screenView = [[ScreenMirrorView alloc] initWithFrame:NSMakeRect(20, 20, 420, 657)];
    [screenView setAutoresizingMask:NSViewHeightSizable];
    [contentView addSubview:screenView];

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
    NSString* appVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    std::string verStr;
    if (appVer && [appVer length] > 0) {
        verStr = std::string("v") + [appVer UTF8String];
    } else {
        verStr = std::string("v") + acast::updater::AutoUpdater::CURRENT_VERSION;
    }
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
    usbStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 18, 400, 24)];
    [usbStatusLabel setStringValue:@"正在侦测连接状态..."];
    [usbStatusLabel setFont:[NSFont systemFontOfSize:11.5]];
    [usbStatusLabel setBezeled:NO];
    [usbStatusLabel setDrawsBackground:NO];
    [usbStatusLabel setEditable:NO];
    [phoneBox addSubview:usbStatusLabel];

    NSButton* backBtn = [[NSButton alloc] initWithFrame:NSMakeRect(430, 15, 75, 28)];
    [backBtn setTitle:@"◀ 返回"];
    [backBtn setToolTip:@"返回键 (Back)"];
    [backBtn setBezelStyle:NSBezelStyleRounded];
    [backBtn setTarget:self];
    [backBtn setAction:@selector(onUsbBackClicked:)];
    [phoneBox addSubview:backBtn];

    NSButton* homeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(510, 15, 75, 28)];
    [homeBtn setTitle:@"○ 桌面"];
    [homeBtn setToolTip:@"主屏键 (Home)"];
    [homeBtn setBezelStyle:NSBezelStyleRounded];
    [homeBtn setTarget:self];
    [homeBtn setAction:@selector(onUsbHomeClicked:)];
    [phoneBox addSubview:homeBtn];

    NSButton* recentsBtn = [[NSButton alloc] initWithFrame:NSMakeRect(590, 15, 75, 28)];
    [recentsBtn setTitle:@"▢ 任务"];
    [recentsBtn setToolTip:@"任务管理 (Tasks)"];
    [recentsBtn setBezelStyle:NSBezelStyleRounded];
    [recentsBtn setTarget:self];
    [recentsBtn setAction:@selector(onRecentsClicked:)];
    [phoneBox addSubview:recentsBtn];

    [contentView addSubview:phoneBox];

    // --- 3.5. 📷 Android 相机扩展中心 ---
    NSBox* cameraBox = [[NSBox alloc] initWithFrame:NSMakeRect(rightX, 395, rightW, 110)];
    [cameraBox setTitle:@"📷 Android 相机扩展中心 (可在 Zoom / FaceTime / 腾讯会议等选用)"];
    [cameraBox setTitleFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];

    cameraStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 62, rightW - 30, 24)];
    [cameraStatusLabel setStringValue:@"扩展状态: 正在检测系统相机扩展..."];
    [cameraStatusLabel setFont:[NSFont systemFontOfSize:11.5]];
    [cameraStatusLabel setTextColor:[NSColor systemGreenColor]];
    [cameraStatusLabel setBezeled:NO];
    [cameraStatusLabel setDrawsBackground:NO];
    [cameraStatusLabel setEditable:NO];
    [cameraBox addSubview:cameraStatusLabel];

    NSButton* installExtBtn = [[NSButton alloc] initWithFrame:NSMakeRect(15, 18, 140, 32)];
    [installExtBtn setTitle:@"相机扩展安装指引"];
    [installExtBtn setBezelStyle:NSBezelStyleRounded];
    [installExtBtn setTarget:self];
    [installExtBtn setAction:@selector(onInstallCameraExtensionClicked:)];
    [cameraBox addSubview:installExtBtn];

    NSButton* openSettingsBtn = [[NSButton alloc] initWithFrame:NSMakeRect(160, 18, 165, 32)];
    [openSettingsBtn setTitle:@"打开“相机扩展”设置..."];
    [openSettingsBtn setBezelStyle:NSBezelStyleRounded];
    [openSettingsBtn setTarget:self];
    [openSettingsBtn setAction:@selector(onOpenExtensionSettingsClicked:)];
    [cameraBox addSubview:openSettingsBtn];

    NSButton* reloadCamBtn = [[NSButton alloc] initWithFrame:NSMakeRect(330, 18, 135, 32)];
    [reloadCamBtn setTitle:@"检测相机扩展状态"];
    [reloadCamBtn setBezelStyle:NSBezelStyleRounded];
    [reloadCamBtn setTarget:self];
    [reloadCamBtn setAction:@selector(onReloadCameraClicked:)];
    [cameraBox addSubview:reloadCamBtn];

    [contentView addSubview:cameraBox];

    // 启动本地虚拟摄像头中继服务与 CoreMediaIO 1080P 30FPS 跨进程直通广播器
    VirtualCameraRelay::GetInstance().StartServer(19996);
    CMIOVirtualCameraBroadcaster::GetInstance().StartBroadcaster();
    [self performSelector:@selector(onReloadCameraClicked:) withObject:nil afterDelay:0.2];
    [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(refreshCameraStatusUI) userInfo:nil repeats:YES];

    // --- 4. 运行状态与事件日志视窗 ---
    NSTextField* logTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX, 365, 200, 20)];
    [logTitle setStringValue:@"📋 运行状态与事件日志"];
    [logTitle setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightBold]];
    [logTitle setBezeled:NO];
    [logTitle setDrawsBackground:NO];
    [logTitle setEditable:NO];
    [contentView addSubview:logTitle];

    NSButton* clearLogBtn = [[NSButton alloc] initWithFrame:NSMakeRect(rightX + rightW - 85, 362, 85, 26)];
    [clearLogBtn setTitle:@"清空"];
    [clearLogBtn setBezelStyle:NSBezelStyleRounded];
    [clearLogBtn setTarget:self];
    [clearLogBtn setAction:@selector(onClearLogClicked:)];
    [contentView addSubview:clearLogBtn];

    NSScrollView* logScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(rightX, 20, rightW, 335)];
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

    // 绑定 Android 摄像头独立硬件流解码回调 (专供虚拟相机与 Zoom / FaceTime，与屏幕投屏双流并发、互不冲突)
    ctl.SetCameraCallback([](const uint8_t* data, size_t size, bool is_key, int64_t pts) {
        CameraStreamDecoder::GetInstance().FeedPacket(data, size, is_key, pts);
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
                CMIOVirtualCameraBroadcaster::GetInstance().ClearLiveFrame();
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

    // 1. 添加局域网对等发现的 Wi-Fi 手机 (iOS / Android)
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

    // 3. 始终提供手动输入 IP 直连项（支持跨网段或开启 AP 广播隔离时的 iOS / Android 私有协议直连）
    [phonePopUp addItemWithTitle:@"⌨️ 手动输入手机 IP 直连 (iOS / Android)..."];
    NSMenuItem* manualItem = [phonePopUp lastItem];
    [manualItem setRepresentedObject:@{ @"type": @"manual" }];
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
    if (!dict || [dict[@"type"] isEqualToString:@"manual"]) {
        NSAlert* alert = [[NSAlert alloc] init];
        [alert setMessageText:@"手动输入手机 IP 直连 (FastMirror 私有协议)"];
        [alert setInformativeText:@"请输入 iPhone 或 Android 手机端 ACast 显示的局域网 IP 地址（默认端口 19999）："];
        [alert addButtonWithTitle:@"立即直连"];
        [alert addButtonWithTitle:@"取消"];

        NSTextField* input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
        [input setPlaceholderString:@"例如: 192.168.2.3"];
        [alert setAccessoryView:input];
        [[alert window] setInitialFirstResponder:input];

        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSString* raw = [[input stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([raw length] > 0) {
                NSString* host = raw;
                uint16_t port = 19999;
                NSRange colon = [raw rangeOfString:@":"];
                if (colon.location != NSNotFound) {
                    host = [raw substringToIndex:colon.location];
                    int p = [[raw substringFromIndex:colon.location + 1] intValue];
                    if (p > 0 && p < 65536) port = (uint16_t)p;
                }
                ctl.ConnectWifiPhone([host UTF8String], port);
            }
        }
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
    [detachedPlaceholderView setHidden:NO];
    [popScreenBtn setTitle:@"⤓ 收回控制屏幕至主窗口"];

    // 关键架构优化：同一个 screenView 实例直接无缝移入独立视窗，硬解管道零中断、零丢帧、永不卡死
    if (standalonePhoneWindow && screenView) {
        NSView* container = [standalonePhoneWindow contentView];
        [screenView removeFromSuperview];
        NSRect cBounds = [container bounds];
        [screenView setFrame:NSMakeRect(0, 0, cBounds.size.width, cBounds.size.height)];
        [screenView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [screenView setHidden:NO];
        [container addSubview:screenView];
        [screenView setNeedsDisplay:YES];
        [standalonePhoneWindow makeFirstResponder:screenView];
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
        [screenView setFrame:NSMakeRect(20, 20, 420, 657)];
        [screenView setAutoresizingMask:NSViewHeightSizable];
        [screenView setHidden:NO];
        [contentView addSubview:screenView];
        [screenView setNeedsDisplay:YES];
        [window makeFirstResponder:screenView];
    }
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
        [standalonePhoneWindow setAcceptsMouseMovedEvents:YES];
    }

    [standalonePhoneWindow makeKeyAndOrderFront:nil];
    if (screenView) {
        [standalonePhoneWindow makeFirstResponder:screenView];
    }
}

- (void)onInstallCameraExtensionClicked:(id)sender {
    CMIOVirtualCameraBroadcaster::GetInstance().ConnectSink();
    bool hasActiveSink = CMIOVirtualCameraBroadcaster::GetInstance().HasActiveSink();
    std::string sinkName = CMIOVirtualCameraBroadcaster::GetInstance().GetActiveSinkName();

    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"macOS 虚拟摄像头使用指南"];
    if (hasActiveSink) {
        NSString* info = [NSString stringWithFormat:
            @"✅ 当前状态：已成功绑定并直连系统相机扩展【%@】！\n\n"
            @"• 您【无需】启动 OBS 软件，也【无需】关闭 macOS SIP。\n"
            @"• ACast 已通过 macOS CoreMediaIO 底层 IOSurface 零拷贝通道直接驱动【%@】(1080P 30FPS)。\n"
            @"• 现在直接打开 FaceTime、Zoom、腾讯会议、飞书或 QuickTime Player，在摄像头列表中选择【%@】，即可实时显示手机摄像头或投屏画面！\n\n"
            @"（可选高级方案：若您希望在关闭 SIP 的开发机上额外注册独立的 ACastCameraExtension 系统扩展，可在终端执行 sudo systemextensionsctl developer on 后点击下方按钮提交注册）",
            SafeStr(sinkName), SafeStr(sinkName), SafeStr(sinkName)];
        [alert setInformativeText:info];
    } else {
        [alert setInformativeText:
            @"在 macOS 上启用虚拟摄像头有两种方式：\n\n"
            @"【方式一：免关 SIP 零配置直通（强烈推荐）】\n"
            @"安装免费开源的 OBS Studio 并在【系统设置 > 通用 > 登录项与扩展 > 相机扩展】中开启 OBS 相机扩展。ACast 会通过 CoreMediaIO 底层通道直接接管并推送 1080P 30FPS 画面（平时完全不需要打开 OBS 软件）！\n\n"
            @"【方式二：激活 ACast 独立原生相机扩展（需关闭 SIP）】\n"
            @"因开源构建未包含付费 Apple 开发者证书，若需注册内置的 ACastCameraExtension，需在恢复模式关闭 SIP 后执行：\n"
            @"  sudo systemextensionsctl developer on\n"
            @"随后点击“提交注册 ACast 扩展”。"];
    }
    [alert addButtonWithTitle:@"知道了"];
    [alert addButtonWithTitle:@"提交注册 ACast 扩展"];
    [alert addButtonWithTitle:@"复制开发者命令"];

    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertSecondButtonReturn) {
        acast::desktop::DesktopController::GetInstance().Log("[相机扩展] 正在向 macOS 提交注册 ACast 独立相机扩展请求...");
        OSSystemExtensionRequest* req = [OSSystemExtensionRequest activationRequestForExtension:@"com.clevercat.acast.camera-extension" queue:dispatch_get_main_queue()];
        req.delegate = self;
        [[OSSystemExtensionManager sharedManager] submitRequest:req];
    } else if (resp == NSAlertThirdButtonReturn) {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:@"sudo systemextensionsctl developer on" forType:NSPasteboardTypeString];
        acast::desktop::DesktopController::GetInstance().Log("[相机扩展] 已复制开发者命令到剪贴板: sudo systemextensionsctl developer on");
    }
}

- (void)onOpenExtensionSettingsClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().Log("[相机扩展] 正在打开 macOS【系统设置 > 通用 > 登录项与扩展 > 相机扩展】...");
    NSURL* url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"];
    if (![[NSWorkspace sharedWorkspace] openURL:url]) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security"]];
    }
}

- (void)refreshCameraStatusUI {
    bool isConnected = CMIOVirtualCameraBroadcaster::GetInstance().HasActiveSink();
    std::string activeName = CMIOVirtualCameraBroadcaster::GetInstance().GetActiveSinkName();
    bool hasClients = VirtualCameraRelay::GetInstance().HasClients();
    uint64_t liveFrames = CMIOVirtualCameraBroadcaster::GetInstance().GetLiveFrames();

    if (isConnected && !activeName.empty()) {
        NSString* statusText = nil;
        if (liveFrames > 0) {
            statusText = [NSString stringWithFormat:@"扩展状态: 🟢 正在实时推流至 [%@] (手机画面已推送 %llu 帧)", SafeStr(activeName), liveFrames];
        } else {
            statusText = [NSString stringWithFormat:@"扩展状态: 🟢 已绑定并激活 [%@] (30FPS 就绪，可在 Zoom / FaceTime 直接选用)", SafeStr(activeName)];
        }
        [cameraStatusLabel setStringValue:statusText];
        [cameraStatusLabel setTextColor:[NSColor systemGreenColor]];
    } else if (hasClients) {
        [cameraStatusLabel setStringValue:@"扩展状态: 🟢 正在向 ACast 独立相机扩展推流中 (30 FPS)"];
        [cameraStatusLabel setTextColor:[NSColor systemGreenColor]];
    }
}

- (void)onReloadCameraClicked:(id)sender {
    acast::desktop::DesktopController::GetInstance().Log("[相机扩展] 正在检测并绑定当前 Mac 系统的相机扩展 (Camera Extensions)...");
    CMIOVirtualCameraBroadcaster::GetInstance().StartBroadcaster();
    auto devices = CMIOVirtualCameraBroadcaster::GetInstance().ScanAvailableSinkDevices();
    bool isConnected = CMIOVirtualCameraBroadcaster::GetInstance().HasActiveSink();
    std::string activeName = CMIOVirtualCameraBroadcaster::GetInstance().GetActiveSinkName();
    bool hasClients = VirtualCameraRelay::GetInstance().HasClients();
    uint64_t sentFrames = CMIOVirtualCameraBroadcaster::GetInstance().GetSentFrames();
    uint64_t liveFrames = CMIOVirtualCameraBroadcaster::GetInstance().GetLiveFrames();

    if (isConnected && !activeName.empty()) {
        for (size_t i = 0; i < devices.size(); ++i) {
            NSString* logMsg = [NSString stringWithFormat:@"[相机扩展] 发现已就绪相机扩展 [%zu]: 名称='%@', UID='%@', 分辨率=%dx%d", 
                i + 1, SafeStr(devices[i].name), SafeStr(devices[i].uid), devices[i].targetWidth, devices[i].targetHeight];
            acast::desktop::DesktopController::GetInstance().Log(logMsg.UTF8String);
        }

        NSString* statusText = nil;
        if (liveFrames > 0) {
            statusText = [NSString stringWithFormat:@"扩展状态: 🟢 正在实时推流至 [%@] (手机画面已推送 %llu 帧)", SafeStr(activeName), liveFrames];
        } else {
            statusText = [NSString stringWithFormat:@"扩展状态: 🟢 已绑定并激活 [%@] (30FPS 就绪，可在 Zoom / FaceTime 直接选用)", SafeStr(activeName)];
        }
        [cameraStatusLabel setStringValue:statusText];
        [cameraStatusLabel setTextColor:[NSColor systemGreenColor]];
        NSString* okLog = [NSString stringWithFormat:@"[相机扩展] ✓ 已成功绑定系统虚拟相机 [%@] (累计发送 %llu 帧)，无需开启 OBS，直接在 Zoom / FaceTime / 腾讯会议中选择【%@】即可使用！",
            SafeStr(activeName), sentFrames, SafeStr(activeName)];
        acast::desktop::DesktopController::GetInstance().Log(okLog.UTF8String);
    } else if (hasClients) {
        [cameraStatusLabel setStringValue:@"扩展状态: 🟢 正在向 ACast 独立相机扩展推流中 (30 FPS)"];
        [cameraStatusLabel setTextColor:[NSColor systemGreenColor]];
        acast::desktop::DesktopController::GetInstance().Log("[相机扩展] 状态检查: 检测到 ACast 独立相机扩展客户端已连接。");
    } else {
        [cameraStatusLabel setStringValue:@"扩展状态: 未检测到已激活的相机扩展 (请点击左侧安装指引配置)"];
        [cameraStatusLabel setTextColor:[NSColor systemOrangeColor]];
        acast::desktop::DesktopController::GetInstance().Log("[相机扩展] 状态检查: 未检测到已激活的系统相机扩展。请点击【相机扩展安装指引】查看配置步骤。");
    }
}

// OSSystemExtensionRequestDelegate
- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request actionForReplacingExtension:(OSSystemExtensionProperties *)existing withExtension:(OSSystemExtensionProperties *)extension {
    return OSSystemExtensionReplacementActionReplace;
}

- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
    acast::desktop::DesktopController::GetInstance().Log("[相机扩展] ⚠️ 系统扩展需要用户批准：请在系统设置【登录项与扩展 > 相机扩展】中允许 ACast！");
    [self onOpenExtensionSettingsClicked:nil];
}

- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    acast::desktop::DesktopController::GetInstance().Log("[相机扩展] 🎉 恭喜！ACast 独立相机扩展已成功激活！可在 Zoom / FaceTime / 腾讯会议等软件中直接选用。");
    [cameraStatusLabel setStringValue:@"扩展状态: ✓ 已成功激活并在系统中就绪！"];
    [cameraStatusLabel setTextColor:[NSColor systemGreenColor]];
}

- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    NSString* errStr = [NSString stringWithFormat:@"[相机扩展] 注册结果: %@ (提示: 本地开发测试可执行 scripts/install_camera_extension.sh)", error.localizedDescription];
    acast::desktop::DesktopController::GetInstance().Log(errStr.UTF8String);
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
