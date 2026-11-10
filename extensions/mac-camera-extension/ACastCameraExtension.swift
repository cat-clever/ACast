import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import CoreGraphics

class ACastCameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    let deviceSource: ACastCameraDeviceSource

    override init() {
        self.deviceSource = ACastCameraDeviceSource()
        super.init()
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerName, .providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            p.name = "ACast Camera Provider"
        }
        if properties.contains(.providerManufacturer) {
            p.manufacturer = "CleverCat ACast"
        }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

class ACastCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private(set) var streamSource: ACastCameraStreamSource!

    override init() {
        super.init()

        let deviceID = UUID(uuidString: "78A4B620-3C1A-4F8A-A4E2-658DE43196E8")!
        self.device = CMIOExtensionDevice(
            localizedName: "ACast 虚拟摄像头 (Android Camera)",
            deviceID: deviceID,
            legacyDeviceID: "ACastVirtualCameraDevice",
            source: self
        )

        self.streamSource = ACastCameraStreamSource(device: self.device)
        do {
            try self.device.addStream(self.streamSource.stream)
        } catch {
            NSLog("ACastCameraDeviceSource: Error adding stream: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceModel, .deviceTransportType]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) {
            p.model = "ACast Android Virtual Camera"
        }
        if properties.contains(.deviceTransportType) {
            p.transportType = 0x76697274 // 'virt'
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

class ACastCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormats: [CMIOExtensionStreamFormat]
    private var activeFormatIdx: Int = 0

    private var timerSource: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.clevercat.acast.stream_queue")
    private var isStreaming = false

    // 实时中继传输状态
    private var socketFd: Int32 = -1
    private var isReceiverRunning = false
    private var receiverThread: Thread?
    private var liveFrameLock = os_unfair_lock()
    private var latestLiveBuffer: CVPixelBuffer?
    private var lastLiveFrameTimestamp: TimeInterval = 0

    init(device: CMIOExtensionDevice) {
        // 创建 1080P 与 720P 格式说明
        var format1080: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: 1920,
            height: 1080,
            extensions: nil,
            formatDescriptionOut: &format1080
        )
        let fmt1080 = CMIOExtensionStreamFormat(
            formatDescription: format1080!,
            maxFrameDuration: CMTime(value: 1, timescale: 15),
            minFrameDuration: CMTime(value: 1, timescale: 60),
            validFrameDurations: nil
        )

        var format720: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: 1280,
            height: 720,
            extensions: nil,
            formatDescriptionOut: &format720
        )
        let fmt720 = CMIOExtensionStreamFormat(
            formatDescription: format720!,
            maxFrameDuration: CMTime(value: 1, timescale: 15),
            minFrameDuration: CMTime(value: 1, timescale: 60),
            validFrameDurations: nil
        )

        self.streamFormats = [fmt1080, fmt720]
        super.init()

        let streamID = UUID(uuidString: "92F13B65-8B2E-4F3D-9457-194C01D396F1")!
        self.stream = CMIOExtensionStream(
            localizedName: "ACast 高清视频流",
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        return streamFormats
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            p.activeFormatIndex = activeFormatIdx
        }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: 30)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex {
            activeFormatIdx = idx
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        return true
    }

    func startStream() throws {
        guard !isStreaming else { return }
        isStreaming = true

        startLiveReceiver()

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.deliverNextFrame()
        }
        timer.resume()
        self.timerSource = timer

        NSLog("ACastCameraExtension: Stream started at 30 FPS.")
    }

    func stopStream() throws {
        isStreaming = false

        if let timer = timerSource {
            timer.cancel()
            timerSource = nil
        }

        stopLiveReceiver()
        NSLog("ACastCameraExtension: Stream stopped.")
    }

    private func deliverNextFrame() {
        guard isStreaming else { return }

        var bufferToSend: CVPixelBuffer? = nil
        let now = Date().timeIntervalSince1970

        os_unfair_lock_lock(&liveFrameLock)
        if now - lastLiveFrameTimestamp < 0.6, let live = latestLiveBuffer {
            bufferToSend = live
        }
        os_unfair_lock_unlock(&liveFrameLock)

        let targetW = (activeFormatIdx == 1) ? 1280 : 1920
        let targetH = (activeFormatIdx == 1) ? 720 : 1080

        if bufferToSend == nil {
            bufferToSend = generateStandbyPixelBuffer(width: targetW, height: targetH)
        }

        guard let pixelBuffer = bufferToSend else { return }

        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard let fmt = formatDesc else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        if status == noErr, let sb = sampleBuffer {
            self.stream.send(sb, discontinuity: [], hostTimeInNanoseconds: mach_absolute_time())
        }
    }

    // MARK: - 优雅待机占位图渲染 (当手机未推流或连接建立中时显示)
    private func generateStandbyPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let res = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard res == noErr, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // 深色科技渐变背景
        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 绘制中央信息卡片底衬
        let cardW: CGFloat = min(w * 0.75, 800)
        let cardH: CGFloat = min(h * 0.55, 340)
        let cardRect = CGRect(x: (w - cardW) / 2, y: (h - cardH) / 2, width: cardW, height: cardH)

        ctx.setFillColor(CGColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 0.95))
        let path = CGPath(roundedRect: cardRect, cornerWidth: 20, cornerHeight: 20, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        ctx.setStrokeColor(CGColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 0.8))
        ctx.setLineWidth(2.5)
        ctx.addPath(path)
        ctx.strokePath()

        return buffer
    }

    // MARK: - 本地中继帧接收器 (连接 ACast 控制端 127.0.0.1:19996)
    private func startLiveReceiver() {
        guard !isReceiverRunning else { return }
        isReceiverRunning = true

        let thread = Thread { [weak self] in
            while let strongSelf = self, strongSelf.isReceiverRunning {
                strongSelf.runReceiverLoop()
                Thread.sleep(forTimeInterval: 0.5) // 断开重连间歇
            }
        }
        thread.name = "ACastCameraReceiverThread"
        thread.start()
        self.receiverThread = thread
    }

    private func stopLiveReceiver() {
        isReceiverRunning = false
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
    }

    private func runReceiverLoop() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return }
        self.socketFd = fd

        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = UInt16(19996).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &sin.sin_addr)

        let connectRes = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectRes < 0 {
            close(fd)
            self.socketFd = -1
            return
        }

        // 成功建立中继，循环读取实时帧
        var headerBuf = [UInt8](repeating: 0, count: 16)
        while isReceiverRunning && self.socketFd >= 0 {
            if !readExact(fd: fd, buf: &headerBuf, length: 16) { break }

            let magic = UInt32(headerBuf[0]) | (UInt32(headerBuf[1]) << 8) | (UInt32(headerBuf[2]) << 16) | (UInt32(headerBuf[3]) << 24)
            if magic != 0x4143414D { continue } // "ACAM"

            let w = Int(UInt32(headerBuf[4]) | (UInt32(headerBuf[5]) << 8) | (UInt32(headerBuf[6]) << 16) | (UInt32(headerBuf[7]) << 24))
            let h = Int(UInt32(headerBuf[8]) | (UInt32(headerBuf[9]) << 8) | (UInt32(headerBuf[10]) << 16) | (UInt32(headerBuf[11]) << 24))
            let len = Int(UInt32(headerBuf[12]) | (UInt32(headerBuf[13]) << 8) | (UInt32(headerBuf[14]) << 16) | (UInt32(headerBuf[15]) << 24))

            if w <= 0 || h <= 0 || len <= 0 || len > 20_000_000 { break }

            var payload = [UInt8](repeating: 0, count: len)
            if !readExact(fd: fd, buf: &payload, length: len) { break }

            // 将收到的 BGRA 像素封装为 IOSurface 支持的 CVPixelBuffer
            var newPb: CVPixelBuffer?
            let liveAttrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            let pbRes = CVPixelBufferCreate(
                kCFAllocatorDefault,
                w,
                h,
                kCVPixelFormatType_32BGRA,
                liveAttrs as CFDictionary,
                &newPb
            )
            if pbRes == noErr, let buffer = newPb {
                CVPixelBufferLockBaseAddress(buffer, [])
                if let destBase = CVPixelBufferGetBaseAddress(buffer) {
                    let destBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                    let srcBytesPerRow = w * 4
                    if destBytesPerRow == srcBytesPerRow {
                        memcpy(destBase, payload, len)
                    } else {
                        payload.withUnsafeBytes { rawPtr in
                            guard let srcBase = rawPtr.baseAddress else { return }
                            let minRow = min(destBytesPerRow, srcBytesPerRow)
                            for y in 0..<h {
                                memcpy(destBase.advanced(by: y * destBytesPerRow),
                                       srcBase.advanced(by: y * srcBytesPerRow),
                                       minRow)
                            }
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])

                os_unfair_lock_lock(&liveFrameLock)
                self.latestLiveBuffer = buffer
                self.lastLiveFrameTimestamp = Date().timeIntervalSince1970
                os_unfair_lock_unlock(&liveFrameLock)
            }
        }

        close(fd)
        if self.socketFd == fd {
            self.socketFd = -1
        }
    }

    private func readExact(fd: Int32, buf: inout [UInt8], length: Int) -> Bool {
        var received = 0
        while received < length && isReceiverRunning {
            let n = buf.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return read(fd, base.advanced(by: received), length - received)
            }
            if n <= 0 { return false }
            received += n
        }
        return received == length
    }
}

