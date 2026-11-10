import UIKit
import Foundation
import AVFoundation
import ReplayKit
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreGraphics
import Darwin

// ============================================================================
// 1. 局域网网络工具与 IPv4 / 子网广播地址探测
// ============================================================================

struct NetworkInterfaceInfo {
    let ip: String
    let broadcast: String
}

enum IOSNetUtils {
    static func currentWiFiInfo() -> NetworkInterfaceInfo {
        var fallbackIp = ""
        var fallbackBcast = "255.255.255.255"

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return NetworkInterfaceInfo(ip: fallbackIp, broadcast: fallbackBcast)
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               let sa = current.pointee.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ipStr = String(cString: hostBuf)
                    if !ipStr.hasPrefix("169.254.") && !ipStr.hasPrefix("127.") {
                        var bcastStr = "255.255.255.255"
                        if let maskSa = current.pointee.ifa_netmask {
                            let ipIn = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                            let maskIn = maskSa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                            var bcastAddr = in_addr(s_addr: (ipIn & maskIn) | (~maskIn))
                            var bcastBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            if inet_ntop(AF_INET, &bcastAddr, &bcastBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                                bcastStr = String(cString: bcastBuf)
                            }
                        }
                        if name == "en0" || name == "bridge100" {
                            return NetworkInterfaceInfo(ip: ipStr, broadcast: bcastStr)
                        } else if fallbackIp.isEmpty {
                            fallbackIp = ipStr
                            fallbackBcast = bcastStr
                        }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return NetworkInterfaceInfo(ip: fallbackIp, broadcast: fallbackBcast)
    }

    static func sendAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return false }
            var totalSent = 0
            let count = data.count
            while totalSent < count {
                let n = Darwin.send(fd, base.advanced(by: totalSent), count - totalSent, 0)
                if n <= 0 {
                    if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                        usleep(1000)
                        continue
                    }
                    return false
                }
                totalSent += n
            }
            return true
        }
    }

    static func readExact(fd: Int32, buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
        var totalRead = 0
        while totalRead < count {
            let n = Darwin.recv(fd, buffer.advanced(by: totalRead), count - totalRead, 0)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            totalRead += n
        }
        return true
    }
}

// ============================================================================
// 2. 后台静音保活引擎 (确保切换至桌面或其他 App 投屏时 TCP 19999 永不断连)
// ============================================================================

final class BackgroundAudioKeepAlive {
    static let shared = BackgroundAudioKeepAlive()
    private var player: AVAudioPlayer?

    func start() {
        if player?.isPlaying == true { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let wavData = Self.makeSilentWavData(durationSeconds: 2, sampleRate: 8000)
            let p = try AVAudioPlayer(data: wavData)
            p.numberOfLoops = -1
            p.volume = 0.0
            p.prepareToPlay()
            p.play()
            self.player = p
        } catch {
            NSLog("[ACast] 后台静音保活初始化提示: \(error)")
        }
    }

    private static func makeSilentWavData(durationSeconds: Int, sampleRate: Int) -> Data {
        let numSamples = durationSeconds * sampleRate
        let dataSize = numSamples * 2
        let totalSize = 36 + dataSize
        var header = Data()

        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var chunkSize = UInt32(totalSize).littleEndian
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "

        var subchunk1Size = UInt32(16).littleEndian
        var audioFormat = UInt16(1).littleEndian
        var numChannels = UInt16(1).littleEndian
        var sr = UInt32(sampleRate).littleEndian
        var byteRate = UInt32(sampleRate * 2).littleEndian
        var blockAlign = UInt16(2).littleEndian
        var bitsPerSample = UInt16(16).littleEndian

        header.append(Data(bytes: &subchunk1Size, count: 4))
        header.append(Data(bytes: &audioFormat, count: 2))
        header.append(Data(bytes: &numChannels, count: 2))
        header.append(Data(bytes: &sr, count: 4))
        header.append(Data(bytes: &byteRate, count: 4))
        header.append(Data(bytes: &blockAlign, count: 2))
        header.append(Data(bytes: &bitsPerSample, count: 2))

        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var subchunk2Size = UInt32(dataSize).littleEndian
        header.append(Data(bytes: &subchunk2Size, count: 4))
        header.append(Data(count: dataSize))
        return header
    }
}

// ============================================================================
// 3. VideoToolbox H.264 零延迟硬件编码器 (输出 Annex-B + FastMirror 协议帧)
// ============================================================================

final class IOSHardwareH264Encoder {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var frameIndex: Int64 = 0
    private var forceNextKeyFrame: Bool = true
    private let msgType: UInt8
    private let onPacketEncoded: (Data, Bool) -> Void

    init(msgType: UInt8, onPacketEncoded: @escaping (Data, Bool) -> Void) {
        self.msgType = msgType
        self.onPacketEncoded = onPacketEncoded
    }

    deinit {
        invalidate()
    }

    func requestKeyFrame() {
        lock.lock()
        forceNextKeyFrame = true
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        if let s = session {
            VTCompressionSessionInvalidate(s)
            session = nil
        }
        lock.unlock()
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        let rawW = CVPixelBufferGetWidth(pixelBuffer)
        let rawH = CVPixelBufferGetHeight(pixelBuffer)
        if rawW == 0 || rawH == 0 { return }

        let maxDim = 1920.0
        let scale = min(1.0, maxDim / Double(max(rawW, rawH)))
        let targetW = Int32((Int(Double(rawW) * scale) / 16) * 16)
        let targetH = Int32((Int(Double(rawH) * scale) / 16) * 16)
        if targetW <= 0 || targetH <= 0 { return }

        lock.lock()
        if session == nil || width != targetW || height != targetH {
            setupSessionLocked(width: targetW, height: targetH)
        }
        guard let vtSession = session else {
            lock.unlock()
            return
        }
        frameIndex += 1
        let needKey = forceNextKeyFrame || (frameIndex % 30 == 1)
        forceNextKeyFrame = false
        lock.unlock()

        var frameProps: CFDictionary? = nil
        if needKey {
            let dict: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
            frameProps = dict as CFDictionary
        }

        var flagsOut = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(
            vtSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
    }

    private func setupSessionLocked(width: Int32, height: Int32) {
        if let old = session {
            VTCompressionSessionInvalidate(old)
            session = nil
        }
        self.width = width
        self.height = height

        let callback: VTCompressionOutputCallback = { (refCon, _, status, _, sampleBuffer) in
            guard status == noErr, let sbuf = sampleBuffer, let ptr = refCon else { return }
            let enc = Unmanaged<IOSHardwareH264Encoder>.fromOpaque(ptr).takeUnretainedValue()
            enc.handleEncodedSample(sbuf)
        }

        var newSession: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard st == noErr, let vt = newSession else { return }

        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 30))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1.0))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 4_500_000))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        VTCompressionSessionPrepareToEncodeFrames(vt)

        self.session = vt
    }

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        var isKeyFrame = true
        let notSyncKey = "NotSync" as CFString
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[notSyncKey] as? Bool {
            isKeyFrame = !notSync
        }

        var annexB = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        if isKeyFrame, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsPtr: UnsafePointer<UInt8>?
            var spsLen: Int = 0
            var count: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsLen, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr,
               let sps = spsPtr, spsLen > 0 {
                annexB.append(contentsOf: startCode)
                annexB.append(sps, count: spsLen)
            }
            var ppsPtr: UnsafePointer<UInt8>?
            var ppsLen: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsLen, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr,
               let pps = ppsPtr, ppsLen > 0 {
                annexB.append(contentsOf: startCode)
                annexB.append(pps, count: ppsLen)
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLen: Int = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let base = dataPtr, totalLen > 4 else { return }

        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= totalLen {
            let naluLen = (Int(bytes[offset]) << 24) |
                          (Int(bytes[offset + 1]) << 16) |
                          (Int(bytes[offset + 2]) << 8) |
                          Int(bytes[offset + 3])
            offset += 4
            if naluLen > 0 && offset + naluLen <= totalLen {
                annexB.append(contentsOf: startCode)
                annexB.append(bytes.advanced(by: offset), count: naluLen)
                offset += naluLen
            } else {
                break
            }
        }

        if annexB.isEmpty { return }
        let pkt = FastMirrorServer.packPacket(msgType: msgType, payload: annexB)
        onPacketEncoded(pkt, isKeyFrame)
    }
}

// ============================================================================
// 4. FastMirror 私有协议服务端 (TCP 19999) + 扩展环回接收桥 (127.0.0.1:19995)
// ============================================================================

final class FastMirrorServer {
    static let shared = FastMirrorServer()

    private let lock = NSLock()
    private var serverFd: Int32 = -1
    private var loopbackServerFd: Int32 = -1
    private var clientFds: [Int32] = []
    private var isRunning = false
    private var cachedVideoKeyFramePacket: Data?
    private var cachedCameraKeyFramePacket: Data?
    private var standbyEncoder: IOSHardwareH264Encoder?

    var onClientCountChanged: ((Int) -> Void)?
    var onRequestKeyFrame: (() -> Void)?

    func start() {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        // 预生成首屏就绪关键帧，确保电脑点击“连接手机”瞬间 0ms 弹出画面，绝不空等
        standbyEncoder = IOSHardwareH264Encoder(msgType: 0x06) { [weak self] pkt, isKey in
            guard let self = self else { return }
            self.lock.lock()
            if self.cachedVideoKeyFramePacket == nil && isKey {
                self.cachedVideoKeyFramePacket = pkt
            }
            self.lock.unlock()
        }
        if let pb = Self.createStandbyPixelBuffer(width: 720, height: 1280) {
            standbyEncoder?.encode(pixelBuffer: pb)
        }

        startTcpAcceptorThread()
        startLoopbackBridgeThread()
    }

    func clientCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return clientFds.count
    }

    static func packPacket(msgType: UInt8, payload: Data) -> Data {
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = 0x46 // 'F'
        header[1] = 0x4D // 'M'
        header[2] = msgType
        header[3] = 0x00

        let len = UInt32(payload.count)
        header[4] = UInt8((len >> 24) & 0xFF)
        header[5] = UInt8((len >> 16) & 0xFF)
        header[6] = UInt8((len >> 8) & 0xFF)
        header[7] = UInt8(len & 0xFF)

        let ptsUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        header[8]  = UInt8((ptsUs >> 56) & 0xFF)
        header[9]  = UInt8((ptsUs >> 48) & 0xFF)
        header[10] = UInt8((ptsUs >> 40) & 0xFF)
        header[11] = UInt8((ptsUs >> 32) & 0xFF)
        header[12] = UInt8((ptsUs >> 24) & 0xFF)
        header[13] = UInt8((ptsUs >> 16) & 0xFF)
        header[14] = UInt8((ptsUs >> 8) & 0xFF)
        header[15] = UInt8(ptsUs & 0xFF)

        var out = Data(header)
        out.append(payload)
        return out
    }

    func broadcastPacket(_ packet: Data, msgType: UInt8, isKeyFrame: Bool) {
        lock.lock()
        if isKeyFrame {
            if msgType == 0x06 {
                cachedVideoKeyFramePacket = packet
            } else if msgType == 0x09 {
                cachedCameraKeyFramePacket = packet
            }
        }
        let targets = clientFds
        lock.unlock()

        if targets.isEmpty { return }

        var removed = false
        for fd in targets {
            if !IOSNetUtils.sendAll(fd: fd, data: packet) {
                lock.lock()
                clientFds.removeAll { $0 == fd }
                Darwin.close(fd)
                removed = true
                lock.unlock()
            }
        }
        if removed {
            notifyClientCount()
        }
    }

    private func startTcpAcceptorThread() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            while self.isRunning {
                let sfd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                if sfd < 0 {
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                var yes: Int32 = 1
                setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(sfd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(sfd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(19999).bigEndian
                addr.sin_addr.s_addr = INADDR_ANY.bigEndian

                let bindRes = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(sfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if bindRes != 0 || Darwin.listen(sfd, 8) != 0 {
                    Darwin.close(sfd)
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                self.lock.lock()
                self.serverFd = sfd
                self.lock.unlock()

                while self.isRunning {
                    var cAddr = sockaddr_in()
                    var cLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let cfd = withUnsafeMutablePointer(to: &cAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.accept(sfd, $0, &cLen)
                        }
                    }
                    if cfd < 0 { break }

                    var one: Int32 = 1
                    setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

                    self.lock.lock()
                    self.clientFds.append(cfd)
                    let vKey = self.cachedVideoKeyFramePacket
                    let cKey = self.cachedCameraKeyFramePacket
                    self.lock.unlock()

                    if let vk = vKey {
                        _ = IOSNetUtils.sendAll(fd: cfd, data: vk)
                    }
                    if let ck = cKey {
                        _ = IOSNetUtils.sendAll(fd: cfd, data: ck)
                    }

                    self.onRequestKeyFrame?()
                    self.notifyClientCount()
                    self.handleDesktopControlClient(cfd)
                }

                Darwin.close(sfd)
                self.lock.lock()
                if self.serverFd == sfd { self.serverFd = -1 }
                self.lock.unlock()
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func handleDesktopControlClient(_ cfd: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1024)
            while let self = self, self.isRunning {
                let n = Darwin.recv(cfd, &buf, buf.count, 0)
                if n <= 0 { break }
            }
            guard let self = self else { return }
            self.lock.lock()
            self.clientFds.removeAll { $0 == cfd }
            Darwin.close(cfd)
            self.lock.unlock()
            self.notifyClientCount()
        }
    }

    private func startLoopbackBridgeThread() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            while self.isRunning {
                let lfd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                if lfd < 0 {
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                var yes: Int32 = 1
                setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(lfd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(19995).bigEndian
                inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

                let bindRes = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if bindRes != 0 || Darwin.listen(lfd, 4) != 0 {
                    Darwin.close(lfd)
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                self.lock.lock()
                self.loopbackServerFd = lfd
                self.lock.unlock()

                while self.isRunning {
                    var cAddr = sockaddr_in()
                    var cLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let extFd = withUnsafeMutablePointer(to: &cAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.accept(lfd, $0, &cLen)
                        }
                    }
                    if extFd < 0 { break }
                    self.readExtensionLoopbackStream(extFd)
                }

                Darwin.close(lfd)
            }
        }
    }

    private func readExtensionLoopbackStream(_ extFd: Int32) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            defer { Darwin.close(extFd) }
            var header = [UInt8](repeating: 0, count: 16)
            while let self = self, self.isRunning {
                if !IOSNetUtils.readExact(fd: extFd, buffer: &header, count: 16) { break }
                let magic = (UInt16(header[0]) << 8) | UInt16(header[1])
                if magic != 0x464D && magic != 0x4D46 { break }

                let msgType = header[2]
                let payloadLen = (Int(header[4]) << 24) |
                                 (Int(header[5]) << 16) |
                                 (Int(header[6]) << 8) |
                                 Int(header[7])
                if payloadLen <= 0 || payloadLen > 10 * 1024 * 1024 { break }

                var fullPacket = Data(count: 16 + payloadLen)
                let ok = fullPacket.withUnsafeMutableBytes { rawBuf -> Bool in
                    guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                    memcpy(base, header, 16)
                    return IOSNetUtils.readExact(fd: extFd, buffer: base.advanced(by: 16), count: payloadLen)
                }
                if !ok { break }

                // 判断是否包含 SPS (NALU type == 7)
                var isKey = false
                fullPacket.withUnsafeBytes { rawBuf in
                    guard let bytes = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let limit = min(fullPacket.count - 5, 128)
                    var i = 16
                    while i < limit {
                        if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                            let nalType = bytes[i+4] & 0x1F
                            if nalType == 7 || nalType == 5 {
                                isKey = true
                                break
                            }
                        }
                        i += 1
                    }
                }

                self.broadcastPacket(fullPacket, msgType: msgType, isKeyFrame: isKey)
            }
        }
    }

    private func notifyClientCount() {
        let count = clientCount()
        DispatchQueue.main.async { [weak self] in
            self?.onClientCountChanged?(count)
        }
    }

    private static func createStandbyPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        if let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: bitmapInfo) {
            ctx.setFillColor(CGColor(red: 0.06, green: 0.09, blue: 0.15, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let cardRect = CGRect(x: 50, y: height / 2 - 160, width: width - 100, height: 320)
            let path = CGPath(roundedRect: cardRect, cornerWidth: 24, cornerHeight: 24, transform: nil)
            ctx.setFillColor(CGColor(red: 0.12, green: 0.17, blue: 0.26, alpha: 1.0))
            ctx.addPath(path)
            ctx.fillPath()

            ctx.setStrokeColor(CGColor(red: 0.24, green: 0.55, blue: 0.98, alpha: 0.9))
            ctx.setLineWidth(3.0)
            ctx.addPath(path)
            ctx.strokePath()

            UIGraphicsPushContext(ctx)
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1.0, y: -1.0)

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: pStyle
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor(red: 0.68, green: 0.82, blue: 1.0, alpha: 1.0),
                .paragraphStyle: pStyle
            ]

            ("iPhone 已通过 FastMirror 私有协议直连" as NSString).draw(
                in: CGRect(x: 70, y: CGFloat(height) / 2 - 90, width: CGFloat(width - 140), height: 80),
                withAttributes: titleAttrs
            )
            ("请在手机端点击【开启全屏广播】或【开启摄像头推流】" as NSString).draw(
                in: CGRect(x: 70, y: CGFloat(height) / 2 + 10, width: CGFloat(width - 140), height: 90),
                withAttributes: subAttrs
            )
            UIGraphicsPopContext()
        }
        return pixelBuffer
    }
}

// ============================================================================
// 5. UDP 局域网对等发现与一键主动直连管理器 (UDP 19998)
// ============================================================================

struct DiscoveredDesktopPeer {
    let name: String
    let ip: String
    let os: String
    var lastSeen: TimeInterval
}

final class IOSPeerDiscovery {
    static let shared = IOSPeerDiscovery()
    private let discoveryPort: UInt16 = 19998
    private let lock = NSLock()
    private var isRunning = false
    private var listenFd: Int32 = -1
    private var desktops: [DiscoveredDesktopPeer] = []

    var onDesktopsChanged: (([DiscoveredDesktopPeer]) -> Void)?

    func start() {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        startListenThread()
        startBeaconThread()
    }

    func deviceDisplayName() -> String {
        let devName = UIDevice.current.name
        if devName.lowercased().contains("iphone") || devName.lowercased().contains("ipad") {
            return devName
        }
        return "iPhone (\(devName))"
    }

    func refreshSearch() {
        DispatchQueue.global(qos: .userInitiated).async {
            let info = IOSNetUtils.currentWiFiInfo()
            let discoverMsg = "{\"cmd\":\"discover_desktop\"}"
            self.sendUdpBroadcast(discoverMsg, broadcastIp: info.broadcast)
            self.broadcastPhoneBeacon(info: info)
        }
    }

    func sendConnectRequest(to desktopIp: String) {
        let trimmed = desktopIp.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }

        DispatchQueue.global(qos: .userInteractive).async {
            let info = IOSNetUtils.currentWiFiInfo()
            let myIp = info.ip.isEmpty ? "127.0.0.1" : info.ip
            let name = self.deviceDisplayName()

            // 1. 先单播一条 phone_beacon 让电脑立刻把 iPhone 收入设备列表
            let beacon = "{\"cmd\":\"phone_beacon\",\"device_name\":\"\(name)\",\"ip\":\"\(myIp)\",\"port\":19999,\"model\":\"iPhone\",\"status\":\"capturing\"}"
            self.sendUdpUnicast(beacon, targetIp: trimmed, port: self.discoveryPort)

            // 2. 紧接着单播发送 connect_request 触发电脑端自动建立 TCP 19999 直连并弹出投屏窗口
            let req = "{\"cmd\":\"connect_request\",\"target_ip\":\"\(trimmed)\",\"phone_ip\":\"\(myIp)\",\"phone_port\":19999,\"phone_name\":\"\(name)\"}"
            self.sendUdpUnicast(req, targetIp: trimmed, port: self.discoveryPort)
        }
    }

    private func broadcastPhoneBeacon(info: NetworkInterfaceInfo) {
        if info.ip.isEmpty { return }
        let name = deviceDisplayName()
        let beacon = "{\"cmd\":\"phone_beacon\",\"device_name\":\"\(name)\",\"ip\":\"\(info.ip)\",\"port\":19999,\"model\":\"iPhone\",\"status\":\"capturing\"}"
        sendUdpBroadcast(beacon, broadcastIp: info.broadcast)
    }

    private func startListenThread() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            while self.isRunning {
                let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
                if fd < 0 {
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = self.discoveryPort.bigEndian
                addr.sin_addr.s_addr = INADDR_ANY.bigEndian

                let bindRes = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if bindRes != 0 {
                    Darwin.close(fd)
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                self.lock.lock()
                self.listenFd = fd
                self.lock.unlock()

                var buf = [UInt8](repeating: 0, count: 2048)
                while self.isRunning {
                    var rAddr = sockaddr_in()
                    var rLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &rAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            Darwin.recvfrom(fd, &buf, buf.count - 1, 0, sa, &rLen)
                        }
                    }
                    if n <= 0 { break }
                    let data = Data(bytes: buf, count: n)
                    guard let msg = String(data: data, encoding: .utf8) else { continue }

                    var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var sinAddr = rAddr.sin_addr
                    var remoteIp = ""
                    if inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        remoteIp = String(cString: ipBuf)
                    }

                    self.handleIncomingPacket(msg: msg, remoteIp: remoteIp)
                }

                Darwin.close(fd)
            }
        }
    }

    private func handleIncomingPacket(msg: String, remoteIp: String) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = json["cmd"] as? String else { return }

        let info = IOSNetUtils.currentWiFiInfo()
        if !remoteIp.isEmpty && remoteIp == info.ip { return }

        if cmd == "desktop_beacon" {
            let devName = (json["device_name"] as? String) ?? "Desktop-PC"
            let os = (json["os"] as? String) ?? "PC"
            var ip = (json["ip"] as? String) ?? remoteIp
            if ip.isEmpty || ip == "127.0.0.1" { ip = remoteIp }
            if ip.isEmpty { return }

            let now = Date().timeIntervalSince1970
            var changed = false
            lock.lock()
            if let idx = desktops.firstIndex(where: { $0.ip == ip }) {
                desktops[idx].lastSeen = now
            } else {
                desktops.append(DiscoveredDesktopPeer(name: devName, ip: ip, os: os, lastSeen: now))
                changed = true
            }
            let snapshot = desktops
            lock.unlock()

            // 收到电脑信标时，立即单播回送一次手机信标，确保双向秒级互认
            if !info.ip.isEmpty {
                let name = deviceDisplayName()
                let reply = "{\"cmd\":\"phone_beacon\",\"device_name\":\"\(name)\",\"ip\":\"\(info.ip)\",\"port\":19999,\"model\":\"iPhone\",\"status\":\"capturing\"}"
                sendUdpUnicast(reply, targetIp: ip, port: discoveryPort)
            }

            if changed {
                DispatchQueue.main.async { [weak self] in
                    self?.onDesktopsChanged?(snapshot)
                }
            }
        } else if cmd == "discover_phone" {
            broadcastPhoneBeacon(info: info)
            if !remoteIp.isEmpty && !info.ip.isEmpty {
                let name = deviceDisplayName()
                let reply = "{\"cmd\":\"phone_beacon\",\"device_name\":\"\(name)\",\"ip\":\"\(info.ip)\",\"port\":19999,\"model\":\"iPhone\",\"status\":\"capturing\"}"
                sendUdpUnicast(reply, targetIp: remoteIp, port: discoveryPort)
            }
        }
    }

    private func startBeaconThread() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.refreshSearch()

            while self.isRunning {
                Thread.sleep(forTimeInterval: 2.0)
                let info = IOSNetUtils.currentWiFiInfo()
                self.broadcastPhoneBeacon(info: info)

                let now = Date().timeIntervalSince1970
                var changed = false
                self.lock.lock()
                let before = self.desktops.count
                self.desktops.removeAll { now - $0.lastSeen > 8.0 }
                if self.desktops.count != before { changed = true }
                let snapshot = self.desktops
                self.lock.unlock()

                if changed {
                    DispatchQueue.main.async { [weak self] in
                        self?.onDesktopsChanged?(snapshot)
                    }
                }
            }
        }
    }

    private func sendUdpBroadcast(_ message: String, broadcastIp: String) {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        if sock < 0 { return }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        guard let data = message.data(using: .utf8) else { return }
        let targets = Set([broadcastIp, "255.255.255.255"])
        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = discoveryPort.bigEndian
            if inet_pton(AF_INET, target, &addr.sin_addr) > 0 {
                data.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else { return }
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            _ = Darwin.sendto(sock, base, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    private func sendUdpUnicast(_ message: String, targetIp: String, port: UInt16) {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        if sock < 0 { return }
        defer { Darwin.close(sock) }

        guard let data = message.data(using: .utf8) else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, targetIp, &addr.sin_addr) > 0 {
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = Darwin.sendto(sock, base, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
}

// ============================================================================
// 6. iOS 摄像头 1080P 30FPS 独立硬件推流器 (直通电脑端与 macOS 虚拟摄像头)
// ============================================================================

final class IOSCameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = IOSCameraStreamer()

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.catclever.acast.ios.camera")
    private var isStreaming = false
    private var useFrontCamera = false
    private var cameraEncoder: IOSHardwareH264Encoder?

    var onStateChanged: ((Bool, Bool) -> Void)?

    func isCameraStreaming() -> Bool {
        return isStreaming
    }

    func requestKeyFrame() {
        cameraEncoder?.requestKeyFrame()
    }

    func toggleCameraStream() {
        if isStreaming {
            stopCamera()
        } else {
            startCamera(front: useFrontCamera)
        }
    }

    func switchCameraPosition() {
        let nextFront = !useFrontCamera
        useFrontCamera = nextFront
        if isStreaming {
            stopCamera { [weak self] in
                self?.startCamera(front: nextFront)
            }
        }
    }

    func startCamera(front: Bool) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self, granted else { return }
            self.sessionQueue.async {
                if self.isStreaming { return }
                self.useFrontCamera = front

                self.cameraEncoder = IOSHardwareH264Encoder(msgType: 0x09) { pkt, isKey in
                    // 同时发送 MSG_CAMERA_FRAME (0x09，驱动 macOS 虚拟相机) 与 MSG_VIDEO_FRAME (0x06，驱动桌面预览视窗)
                    FastMirrorServer.shared.broadcastPacket(pkt, msgType: 0x09, isKeyFrame: isKey)
                    var videoCopy = pkt
                    videoCopy[2] = 0x06
                    FastMirrorServer.shared.broadcastPacket(videoCopy, msgType: 0x06, isKeyFrame: isKey)
                }

                self.captureSession.beginConfiguration()
                for input in self.captureSession.inputs {
                    self.captureSession.removeInput(input)
                }
                for output in self.captureSession.outputs {
                    self.captureSession.removeOutput(output)
                }

                if self.captureSession.canSetSessionPreset(.hd1920x1080) {
                    self.captureSession.sessionPreset = .hd1920x1080
                } else if self.captureSession.canSetSessionPreset(.hd1280x720) {
                    self.captureSession.sessionPreset = .hd1280x720
                }

                let pos: AVCaptureDevice.Position = front ? .front : .back
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) ?? AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.captureSession.canAddInput(input) else {
                    self.captureSession.commitConfiguration()
                    return
                }
                self.captureSession.addInput(input)

                do {
                    try device.lockForConfiguration()
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    device.unlockForConfiguration()
                } catch {}

                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.setSampleBufferDelegate(self, queue: self.sessionQueue)
                if self.captureSession.canAddOutput(output) {
                    self.captureSession.addOutput(output)
                }

                self.captureSession.commitConfiguration()
                self.captureSession.startRunning()
                self.isStreaming = true

                DispatchQueue.main.async {
                    self.onStateChanged?(true, front)
                }
            }
        }
    }

    func stopCamera(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.cameraEncoder?.invalidate()
            self.cameraEncoder = nil
            self.isStreaming = false
            DispatchQueue.main.async {
                self.onStateChanged?(false, self.useFrontCamera)
                completion?()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isStreaming, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        cameraEncoder?.encode(pixelBuffer: pb, pts: pts)
    }
}

// ============================================================================
// 7. iOS 主界面控制器 (深色科技仪表盘 + 自动发现电脑 + 手动 IP 直连 + 屏幕/相机推流)
// ============================================================================

final class MainViewController: UIViewController {
    private let statusBadge = UILabel()
    private let ipInfoLabel = UILabel()
    private let clientCountLabel = UILabel()
    private let desktopsStack = UIStackView()
    private let manualIpField = UITextField()
    private let inAppCaptureBtn = UIButton(type: .system)
    private let cameraStreamBtn = UIButton(type: .system)
    private let switchCamBtn = UIButton(type: .system)
    private var broadcastPicker: RPSystemBroadcastPickerView?

    private var inAppScreenEncoder: IOSHardwareH264Encoder?
    private var isInAppScreenCapturing = false
    private var refreshTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0)
        setupUI()
        bindServices()

        BackgroundAudioKeepAlive.shared.start()
        FastMirrorServer.shared.start()
        IOSPeerDiscovery.shared.start()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateNetworkHeader()
        }
        updateNetworkHeader()
    }

    private func setupUI() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        view.addSubview(scrollView)

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24)
        ])

        // 1. 顶部标题与私有协议状态卡片
        let headerCard = makeCard()
        let titleLabel = UILabel()
        titleLabel.text = "ACast 跨平台投屏 (iOS)"
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white

        statusBadge.text = "● FastMirror 私有协议服务已就绪 (:19999)"
        statusBadge.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        statusBadge.textColor = UIColor(red: 0.25, green: 0.88, blue: 0.52, alpha: 1.0)

        ipInfoLabel.text = "本机局域网 IP: 正在获取..."
        ipInfoLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        ipInfoLabel.textColor = UIColor(white: 0.82, alpha: 1.0)

        clientCountLabel.text = "当前已连接电脑控制端: 0 台"
        clientCountLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        clientCountLabel.textColor = UIColor(red: 0.55, green: 0.76, blue: 1.0, alpha: 1.0)

        let hStack = UIStackView(arrangedSubviews: [titleLabel, statusBadge, ipInfoLabel, clientCountLabel])
        hStack.axis = .vertical
        hStack.spacing = 6
        hStack.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(hStack)
        pinInside(hStack, card: headerCard)
        contentStack.addArrangedSubview(headerCard)

        // 2. 屏幕共享与摄像头推流控制卡片
        let streamCard = makeCard()
        let streamTitle = makeSectionTitle("🎬 第一步：启动画面采集源 (屏幕 / 摄像头)")

        // 系统级跨应用广播按钮 (内嵌 RPSystemBroadcastPickerView)
        let pickerContainer = UIView()
        pickerContainer.backgroundColor = UIColor(red: 0.16, green: 0.44, blue: 0.92, alpha: 1.0)
        pickerContainer.layer.cornerRadius = 12
        pickerContainer.translatesAutoresizingMaskIntoConstraints = false
        pickerContainer.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let pickerLabel = UILabel()
        pickerLabel.text = "🖥️ 开启 iOS 全系统跨应用屏幕广播"
        pickerLabel.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        pickerLabel.textColor = .white
        pickerLabel.textAlignment = .center
        pickerLabel.translatesAutoresizingMaskIntoConstraints = false
        pickerContainer.addSubview(pickerLabel)
        NSLayoutConstraint.activate([
            pickerLabel.centerXAnchor.constraint(equalTo: pickerContainer.centerXAnchor),
            pickerLabel.centerYAnchor.constraint(equalTo: pickerContainer.centerYAnchor)
        ])

        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        picker.showsMicrophoneButton = false
        // 不强制限定 preferredExtension，兼容爱思助手/AltStore 重签名修改 BundleID 后的扩展发现
        for subview in picker.subviews {
            if let btn = subview as? UIButton {
                btn.setImage(nil, for: .normal)
                btn.setTitle(nil, for: .normal)
            }
        }
        picker.translatesAutoresizingMaskIntoConstraints = false
        pickerContainer.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: pickerContainer.topAnchor),
            picker.leadingAnchor.constraint(equalTo: pickerContainer.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: pickerContainer.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: pickerContainer.bottomAnchor)
        ])
        self.broadcastPicker = picker

        // 应用内免扩展高速采集按钮 (即使自签工具剥离了 appex 扩展也可 100% 正常工作)
        styleActionButton(inAppCaptureBtn, title: "📱 开启应用内免扩展屏幕投屏 (兼容全部自签)", bgColor: UIColor(red: 0.18, green: 0.25, blue: 0.38, alpha: 1.0))
        inAppCaptureBtn.addTarget(self, action: #selector(onInAppCaptureTapped), for: .touchUpInside)

        // 摄像头推流与前后置切换行
        styleActionButton(cameraStreamBtn, title: "📷 开启 1080P 摄像头推流 (直通虚拟相机)", bgColor: UIColor(red: 0.14, green: 0.56, blue: 0.42, alpha: 1.0))
        cameraStreamBtn.addTarget(self, action: #selector(onCameraStreamTapped), for: .touchUpInside)

        styleActionButton(switchCamBtn, title: "🔄 切换前/后", bgColor: UIColor(red: 0.22, green: 0.26, blue: 0.34, alpha: 1.0))
        switchCamBtn.widthAnchor.constraint(equalToConstant: 110).isActive = true
        switchCamBtn.addTarget(self, action: #selector(onSwitchCameraTapped), for: .touchUpInside)

        let camRow = UIStackView(arrangedSubviews: [cameraStreamBtn, switchCamBtn])
        camRow.axis = .horizontal
        camRow.spacing = 10

        let sStack = UIStackView(arrangedSubviews: [streamTitle, pickerContainer, inAppCaptureBtn, camRow])
        sStack.axis = .vertical
        sStack.spacing = 10
        sStack.translatesAutoresizingMaskIntoConstraints = false
        streamCard.addSubview(sStack)
        pinInside(sStack, card: streamCard)
        contentStack.addArrangedSubview(streamCard)

        // 3. 局域网电脑控制端自动发现与一键直连卡片
        let discoveryCard = makeCard()
        let discHeaderRow = UIStackView()
        discHeaderRow.axis = .horizontal
        discHeaderRow.distribution = .equalSpacing
        let discTitle = makeSectionTitle("💻 第二步：点击电脑一键直连 (UDP 19998)")
        let refreshBtn = UIButton(type: .system)
        refreshBtn.setTitle("刷新搜索", for: .normal)
        refreshBtn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        refreshBtn.setTitleColor(UIColor(red: 0.40, green: 0.72, blue: 1.0, alpha: 1.0), for: .normal)
        refreshBtn.addTarget(self, action: #selector(onRefreshDesktopsTapped), for: .touchUpInside)
        discHeaderRow.addArrangedSubview(discTitle)
        discHeaderRow.addArrangedSubview(refreshBtn)

        desktopsStack.axis = .vertical
        desktopsStack.spacing = 8
        rebuildDesktopsList([])

        // 手动输入电脑 IP 直连行
        manualIpField.placeholder = "或手动输入电脑 IP (如 192.168.2.3)"
        manualIpField.attributedPlaceholder = NSAttributedString(
            string: "或手动输入电脑 IP (如 192.168.2.3)",
            attributes: [.foregroundColor: UIColor(white: 0.48, alpha: 1.0)]
        )
        manualIpField.textColor = .white
        manualIpField.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        manualIpField.backgroundColor = UIColor(red: 0.06, green: 0.08, blue: 0.13, alpha: 1.0)
        manualIpField.layer.cornerRadius = 10
        manualIpField.layer.borderWidth = 1
        manualIpField.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).cgColor
        manualIpField.keyboardType = .numbersAndPunctuation
        manualIpField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        manualIpField.leftViewMode = .always
        manualIpField.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let manualConnectBtn = UIButton(type: .system)
        styleActionButton(manualConnectBtn, title: "发起直连", bgColor: UIColor(red: 0.20, green: 0.48, blue: 0.94, alpha: 1.0))
        manualConnectBtn.widthAnchor.constraint(equalToConstant: 96).isActive = true
        manualConnectBtn.heightAnchor.constraint(equalToConstant: 42).isActive = true
        manualConnectBtn.addTarget(self, action: #selector(onManualConnectTapped), for: .touchUpInside)

        let manualRow = UIStackView(arrangedSubviews: [manualIpField, manualConnectBtn])
        manualRow.axis = .horizontal
        manualRow.spacing = 8

        let dStack = UIStackView(arrangedSubviews: [discHeaderRow, desktopsStack, manualRow])
        dStack.axis = .vertical
        dStack.spacing = 10
        dStack.translatesAutoresizingMaskIntoConstraints = false
        discoveryCard.addSubview(dStack)
        pinInside(dStack, card: discoveryCard)
        contentStack.addArrangedSubview(discoveryCard)
    }

    private func bindServices() {
        FastMirrorServer.shared.onClientCountChanged = { [weak self] count in
            guard let self = self else { return }
            if count > 0 {
                self.clientCountLabel.text = "🎉 已连接电脑控制端: \(count) 台 (FastMirror 极速直连中)"
                self.clientCountLabel.textColor = UIColor(red: 0.25, green: 0.92, blue: 0.55, alpha: 1.0)
            } else {
                self.clientCountLabel.text = "当前已连接电脑控制端: 0 台 (等待电脑连接或点击下方电脑直连)"
                self.clientCountLabel.textColor = UIColor(red: 0.55, green: 0.76, blue: 1.0, alpha: 1.0)
            }
        }

        FastMirrorServer.shared.onRequestKeyFrame = { [weak self] in
            self?.inAppScreenEncoder?.requestKeyFrame()
            IOSCameraStreamer.shared.requestKeyFrame()
        }

        IOSPeerDiscovery.shared.onDesktopsChanged = { [weak self] list in
            self?.rebuildDesktopsList(list)
        }

        IOSCameraStreamer.shared.onStateChanged = { [weak self] running, isFront in
            guard let self = self else { return }
            if running {
                let posStr = isFront ? "前置" : "后置"
                self.cameraStreamBtn.setTitle("⏹ 停止摄像头推流 (当前: \(posStr) 1080P)", for: .normal)
                self.cameraStreamBtn.backgroundColor = UIColor(red: 0.82, green: 0.24, blue: 0.26, alpha: 1.0)
            } else {
                self.cameraStreamBtn.setTitle("📷 开启 1080P 摄像头推流 (直通虚拟相机)", for: .normal)
                self.cameraStreamBtn.backgroundColor = UIColor(red: 0.14, green: 0.56, blue: 0.42, alpha: 1.0)
            }
        }
    }

    private func updateNetworkHeader() {
        let info = IOSNetUtils.currentWiFiInfo()
        if info.ip.isEmpty {
            ipInfoLabel.text = "本机局域网 IP: 未检测到 Wi-Fi (请连接与电脑相同的局域网)"
        } else {
            ipInfoLabel.text = "本机局域网 IP: \(info.ip)  |  协议端口: 19999"
        }
    }

    private func rebuildDesktopsList(_ list: [DiscoveredDesktopPeer]) {
        for sub in desktopsStack.arrangedSubviews {
            desktopsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        if list.isEmpty {
            let emptyLabel = UILabel()
            emptyLabel.text = "正在自动搜寻局域网内的 Mac / Windows 控制端...\n(您也可以直接在电脑端选择本 iPhone，或在下方输入电脑 IP)"
            emptyLabel.numberOfLines = 0
            emptyLabel.font = UIFont.systemFont(ofSize: 12.5)
            emptyLabel.textColor = UIColor(white: 0.62, alpha: 1.0)
            desktopsStack.addArrangedSubview(emptyLabel)
            return
        }

        for peer in list {
            let row = UIButton(type: .system)
            row.backgroundColor = UIColor(red: 0.13, green: 0.18, blue: 0.28, alpha: 1.0)
            row.layer.cornerRadius = 10
            row.contentHorizontalAlignment = .center
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
            row.setTitle("💻 \(peer.name) (\(peer.ip))  —  点击立即直连", for: .normal)
            row.setTitleColor(.white, for: .normal)
            row.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            row.accessibilityHint = peer.ip
            row.addTarget(self, action: #selector(onDesktopPeerRowTapped(_:)), for: .touchUpInside)
            desktopsStack.addArrangedSubview(row)
        }
    }

    @objc private func onDesktopPeerRowTapped(_ sender: UIButton) {
        guard let ip = sender.accessibilityHint, !ip.isEmpty else { return }
        IOSPeerDiscovery.shared.sendConnectRequest(to: ip)
        statusBadge.text = "● 已向电脑 (\(ip)) 发送 FastMirror 直连请求！"
    }

    @objc private func onManualConnectTapped() {
        view.endEditing(true)
        let ip = (manualIpField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        IOSPeerDiscovery.shared.sendConnectRequest(to: ip)
        statusBadge.text = "● 已向电脑 (\(ip)) 发送 FastMirror 直连请求！"
    }

    @objc private func onRefreshDesktopsTapped() {
        IOSPeerDiscovery.shared.refreshSearch()
        updateNetworkHeader()
    }

    @objc private func onInAppCaptureTapped() {
        let recorder = RPScreenRecorder.shared()
        if isInAppScreenCapturing {
            recorder.stopCapture { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isInAppScreenCapturing = false
                    self.inAppScreenEncoder?.invalidate()
                    self.inAppScreenEncoder = nil
                    self.inAppCaptureBtn.setTitle("📱 开启应用内免扩展屏幕投屏 (兼容全部自签)", for: .normal)
                    self.inAppCaptureBtn.backgroundColor = UIColor(red: 0.18, green: 0.25, blue: 0.38, alpha: 1.0)
                }
            }
            return
        }

        let enc = IOSHardwareH264Encoder(msgType: 0x06) { pkt, isKey in
            FastMirrorServer.shared.broadcastPacket(pkt, msgType: 0x06, isKeyFrame: isKey)
        }
        self.inAppScreenEncoder = enc

        recorder.isMicrophoneEnabled = false
        recorder.startCapture(handler: { [weak self] sampleBuffer, bufferType, _ in
            if bufferType == .video, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                self?.inAppScreenEncoder?.encode(pixelBuffer: pb, pts: pts)
            }
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error == nil {
                    self.isInAppScreenCapturing = true
                    self.inAppCaptureBtn.setTitle("⏹ 停止应用内屏幕投屏 (实时推流中)", for: .normal)
                    self.inAppCaptureBtn.backgroundColor = UIColor(red: 0.82, green: 0.24, blue: 0.26, alpha: 1.0)
                } else {
                    self.inAppScreenEncoder?.invalidate()
                    self.inAppScreenEncoder = nil
                }
            }
        })
    }

    @objc private func onCameraStreamTapped() {
        IOSCameraStreamer.shared.toggleCameraStream()
    }

    @objc private func onSwitchCameraTapped() {
        IOSCameraStreamer.shared.switchCameraPosition()
    }

    private func makeCard() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(red: 0.09, green: 0.12, blue: 0.18, alpha: 1.0)
        v.layer.cornerRadius = 16
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor(white: 1.0, alpha: 0.08).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        l.textColor = .white
        return l
    }

    private func styleActionButton(_ btn: UIButton, title: String, bgColor: UIColor) {
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        btn.backgroundColor = bgColor
        btn.layer.cornerRadius = 11
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func pinInside(_ subview: UIView, card: UIView) {
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            subview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            subview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            subview.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UIApplication.shared.isIdleTimerDisabled = true
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = MainViewController()
        window?.makeKeyAndVisible()
        return true
    }
}
