import ReplayKit
import Foundation
import UIKit
import VideoToolbox
import CoreMedia
import CoreVideo
import Darwin

// ============================================================================
// FastMirror H.264 硬件编码与双通道推流器 (ReplayKit 扩展进程)
// 1. 优先通过 127.0.0.1:19995 零配置环回桥接转发给主应用 ACast (免 App Group 签名依赖)
// 2. 若主应用未在后台运行，自动接管直连监听 TCP 19999 与 UDP 19998 发现广播
// ============================================================================

final class ExtensionFastMirrorBridge {
    static let shared = ExtensionFastMirrorBridge()

    private let lock = NSLock()
    private let loopbackSendLock = NSLock()
    private var compressionSession: VTCompressionSession?
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    private var frameCount: Int64 = 0

    // 主应用环回连接 (127.0.0.1:19995)
    private var loopbackFd: Int32 = -1
    private var lastLoopbackAttempt: TimeInterval = 0

    // 独立备用服务端与主动出站直连池
    private var serverFd: Int32 = -1
    private var udpListenFd: Int32 = -1
    private var clientFds: [Int32] = []
    private var clientFdIps: [Int32: String] = [:]
    private var connectedDesktopIps: Set<String> = []
    private var connectingDesktopIps: Set<String> = []
    private var discoveredDesktopIps: Set<String> = []
    private var cachedKeyFramePacket: Data?
    private var isRunning = false

    func start() {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        _ = connectLoopbackIfNeeded()
        startFallbackServerIfNeeded()
        startExtensionUdpListener()
        startExtensionDiscoveryBeacon()
    }

    func stop() {
        lock.lock()
        isRunning = false
        if loopbackFd >= 0 {
            Darwin.close(loopbackFd)
            loopbackFd = -1
        }
        if serverFd >= 0 {
            Darwin.close(serverFd)
            serverFd = -1
        }
        if udpListenFd >= 0 {
            Darwin.close(udpListenFd)
            udpListenFd = -1
        }
        for fd in clientFds {
            Darwin.close(fd)
        }
        clientFds.removeAll()
        clientFdIps.removeAll()
        connectedDesktopIps.removeAll()
        connectingDesktopIps.removeAll()
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        lock.unlock()
    }

    func encodeVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let rawW = CVPixelBufferGetWidth(imageBuffer)
        let rawH = CVPixelBufferGetHeight(imageBuffer)
        if rawW == 0 || rawH == 0 { return }

        // 控制扩展内编码分辨率上限 (最高 1080p，16 字节对齐，确保 ReplayKit 50MB 内存安全)
        let maxDim = 1920.0
        let scale = min(1.0, maxDim / Double(max(rawW, rawH)))
        let targetW = Int32((Int(Double(rawW) * scale) / 16) * 16)
        let targetH = Int32((Int(Double(rawH) * scale) / 16) * 16)
        if targetW <= 0 || targetH <= 0 { return }

        lock.lock()
        if compressionSession == nil || currentWidth != targetW || currentHeight != targetH {
            setupCompressionSessionLocked(width: targetW, height: targetH)
        }
        guard let session = compressionSession else {
            lock.unlock()
            return
        }
        frameCount += 1
        let forceKey = (frameCount % 30 == 1)
        lock.unlock()

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var props: CFDictionary? = nil
        if forceKey {
            let dict: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
            props = dict as CFDictionary
        }

        var flagsOut = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
    }

    private func setupCompressionSessionLocked(width: Int32, height: Int32) {
        if let old = compressionSession {
            VTCompressionSessionInvalidate(old)
            compressionSession = nil
        }
        currentWidth = width
        currentHeight = height

        let callback: VTCompressionOutputCallback = { (outputCallbackRefCon, _, status, _, sampleBuffer) in
            guard status == noErr, let sbuf = sampleBuffer, let refCon = outputCallbackRefCon else { return }
            let bridge = Unmanaged<ExtensionFastMirrorBridge>.fromOpaque(refCon).takeUnretainedValue()
            bridge.handleEncodedSampleBuffer(sbuf)
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let vtSession = session else { return }

        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 30))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1.0))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 4_500_000))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        VTCompressionSessionPrepareToEncodeFrames(vtSession)

        compressionSession = vtSession
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
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

        if isKeyFrame, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsPtr: UnsafePointer<UInt8>?
            var spsSize: Int = 0
            var spsCount: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil) == noErr,
               let sps = spsPtr, spsSize > 0 {
                annexB.append(contentsOf: startCode)
                annexB.append(sps, count: spsSize)
            }

            var ppsPtr: UnsafePointer<UInt8>?
            var ppsSize: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil) == noErr,
               let pps = ppsPtr, ppsSize > 0 {
                annexB.append(contentsOf: startCode)
                annexB.append(pps, count: ppsSize)
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLen: Int = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let basePtr = dataPtr, totalLen > 4 else { return }

        let rawBytes = UnsafeRawPointer(basePtr).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= totalLen {
            let naluLen = (Int(rawBytes[offset]) << 24) |
                          (Int(rawBytes[offset + 1]) << 16) |
                          (Int(rawBytes[offset + 2]) << 8) |
                          Int(rawBytes[offset + 3])
            offset += 4
            if naluLen > 0 && offset + naluLen <= totalLen {
                annexB.append(contentsOf: startCode)
                annexB.append(rawBytes.advanced(by: offset), count: naluLen)
                offset += naluLen
            } else {
                break
            }
        }

        if annexB.isEmpty { return }

        let packet = Self.packFastMirrorPacket(msgType: 0x06, payload: annexB)
        dispatchPacket(packet, isKeyFrame: isKeyFrame)
    }

    static func packFastMirrorPacket(msgType: UInt8, payload: Data) -> Data {
        var header = [UInt8](repeating: 0, count: 16)
        // MAGIC: 0x46 0x4D ("FM")
        header[0] = 0x46
        header[1] = 0x4D
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

        var packet = Data(header)
        packet.append(payload)
        return packet
    }

    private func dispatchPacket(_ packet: Data, isKeyFrame: Bool) {
        lock.lock()
        if isKeyFrame {
            cachedKeyFramePacket = packet
        }
        let clients = clientFds
        lock.unlock()

        // 1. 优先向已建立直连的电脑客户端广播 (含主动出站直连电脑 19990 端口)
        if !clients.isEmpty {
            for cfd in clients {
                if !Self.sendAll(fd: cfd, data: packet) {
                    lock.lock()
                    clientFds.removeAll { $0 == cfd }
                    if let ip = clientFdIps.removeValue(forKey: cfd) {
                        connectedDesktopIps.remove(ip)
                    }
                    Darwin.close(cfd)
                    lock.unlock()
                }
            }
            return
        }

        // 2. 若当前尚无直接电脑连接，推送至主应用环回桥 (127.0.0.1:19995)
        _ = sendOverLoopback(packet)
    }

    private func sendOverLoopback(_ packet: Data) -> Bool {
        if !connectLoopbackIfNeeded() { return false }
        lock.lock()
        let fd = loopbackFd
        lock.unlock()
        if fd < 0 { return false }

        loopbackSendLock.lock()
        let ok = Self.sendAll(fd: fd, data: packet)
        loopbackSendLock.unlock()

        if !ok {
            lock.lock()
            if loopbackFd == fd {
                Darwin.close(loopbackFd)
                loopbackFd = -1
            }
            lock.unlock()
        }
        return ok
    }

    private func connectLoopbackIfNeeded() -> Bool {
        lock.lock()
        if loopbackFd >= 0 {
            lock.unlock()
            return true
        }
        let now = Date().timeIntervalSince1970
        if now - lastLoopbackAttempt < 1.0 {
            lock.unlock()
            return false
        }
        lastLoopbackAttempt = now
        lock.unlock()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(19995).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res == 0 {
            lock.lock()
            loopbackFd = fd
            let keyPkt = cachedKeyFramePacket
            lock.unlock()
            if let kp = keyPkt {
                loopbackSendLock.lock()
                _ = Self.sendAll(fd: fd, data: kp)
                loopbackSendLock.unlock()
            }
            return true
        } else {
            Darwin.close(fd)
            return false
        }
    }

    private func startFallbackServerIfNeeded() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            while self.isRunning {
                self.lock.lock()
                let existing = self.serverFd
                self.lock.unlock()

                if existing < 0 {
                    let sfd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                    if sfd >= 0 {
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
                        if bindRes == 0 && Darwin.listen(sfd, 5) == 0 {
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
                                let keyPkt = self.cachedKeyFramePacket
                                self.lock.unlock()

                                if let kp = keyPkt {
                                    _ = Self.sendAll(fd: cfd, data: kp)
                                }
                                self.drainClientSocketAsync(cfd)
                            }
                        } else {
                            Darwin.close(sfd)
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 2.0)
            }
        }
    }

    private static func readExact(fd: Int32, buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
        var totalRead = 0
        while totalRead < count {
            let n = Darwin.recv(fd, buffer.advanced(by: totalRead), count - totalRead, 0)
            if n <= 0 {
                if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(1000)
                    continue
                }
                return false
            }
            totalRead += n
        }
        return true
    }

    private func drainClientSocketAsync(_ cfd: Int32) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var header = [UInt8](repeating: 0, count: 16)
            while let self = self, self.isRunning {
                if !Self.readExact(fd: cfd, buffer: &header, count: 16) { break }
                let magic = (UInt16(header[0]) << 8) | UInt16(header[1])
                if magic != 0x464D && magic != 0x4D46 { break }

                let msgType = header[2]
                let payloadLen = (Int(header[4]) << 24) |
                                 (Int(header[5]) << 16) |
                                 (Int(header[6]) << 8) |
                                 Int(header[7])
                if payloadLen < 0 || payloadLen > 10 * 1024 * 1024 { break }

                var fullPacket = Data(count: 16 + payloadLen)
                let ok = fullPacket.withUnsafeMutableBytes { rawBuf -> Bool in
                    guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                    memcpy(base, header, 16)
                    if payloadLen == 0 { return true }
                    return Self.readExact(fd: cfd, buffer: base.advanced(by: 16), count: payloadLen)
                }
                if !ok { break }

                if msgType >= 0x10 && msgType <= 0x3F {
                    // 优先通过环回桥 (127.0.0.1:19995) 转发给主应用 IOSRemoteControlEngine 处理
                    let forwarded = self.sendOverLoopback(fullPacket)
                    if !forwarded && (msgType == 0x22 || msgType == 0x30) && payloadLen > 0 {
                        let payload = fullPacket.subdata(in: 16..<(16 + payloadLen))
                        if let text = String(data: payload, encoding: .utf8), !text.isEmpty {
                            UIPasteboard.general.string = text
                        }
                    }
                }
            }
            guard let self = self else { return }
            self.lock.lock()
            self.clientFds.removeAll { $0 == cfd }
            if let ip = self.clientFdIps.removeValue(forKey: cfd) {
                self.connectedDesktopIps.remove(ip)
            }
            Darwin.close(cfd)
            self.lock.unlock()
        }
    }

    func connectToDesktop(ip: String, port: UInt16 = 19990) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "127.0.0.1" { return }

        lock.lock()
        if connectedDesktopIps.contains(trimmed) || connectingDesktopIps.contains(trimmed) {
            lock.unlock()
            return
        }
        connectingDesktopIps.insert(trimmed)
        lock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            defer {
                self.lock.lock()
                self.connectingDesktopIps.remove(trimmed)
                self.lock.unlock()
            }

            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { return }

            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            if inet_pton(AF_INET, trimmed, &addr.sin_addr) <= 0 {
                Darwin.close(fd)
                return
            }

            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            var ok = (rc == 0)
            if !ok && (errno == EINPROGRESS || errno == EWOULDBLOCK) {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = Darwin.poll(&pfd, 1, 1500)
                if pr > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                    var soErr: Int32 = 0
                    var errLen = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &errLen) == 0 && soErr == 0 {
                        ok = true
                    }
                }
            }

            if !ok {
                Darwin.close(fd)
                return
            }

            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            }

            self.lock.lock()
            if self.connectedDesktopIps.contains(trimmed) {
                self.lock.unlock()
                Darwin.close(fd)
                return
            }
            self.connectedDesktopIps.insert(trimmed)
            self.clientFds.append(fd)
            self.clientFdIps[fd] = trimmed
            let keyPkt = self.cachedKeyFramePacket
            self.lock.unlock()

            if let kp = keyPkt {
                _ = Self.sendAll(fd: fd, data: kp)
            }
            self.drainClientSocketAsync(fd)
        }
    }

    private func startExtensionUdpListener() {
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
                addr.sin_port = UInt16(19998).bigEndian
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
                self.udpListenFd = fd
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
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let cmd = json["cmd"] as? String else { continue }

                    var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var sinAddr = rAddr.sin_addr
                    var remoteIp = ""
                    if inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        remoteIp = String(cString: ipBuf)
                    }

                    let (myIp, _) = Self.getLocalWiFiAddressAndBroadcast()
                    if !remoteIp.isEmpty && remoteIp == myIp { continue }

                    if cmd == "request_reverse_connect" {
                        var targetIp = (json["desktop_ip"] as? String) ?? (json["ip"] as? String) ?? remoteIp
                        if targetIp.isEmpty || targetIp == "127.0.0.1" { targetIp = remoteIp }
                        let tcpPort = UInt16((json["tcp_port"] as? Int) ?? 19990)
                        if !targetIp.isEmpty {
                            self.connectToDesktop(ip: targetIp, port: tcpPort)
                        }
                    } else if cmd == "discover_phone" || cmd == "desktop_beacon" {
                        if !myIp.isEmpty {
                            let (_, bcast) = Self.getLocalWiFiAddressAndBroadcast()
                            let beacon = "{\"cmd\":\"phone_beacon\",\"device_name\":\"iPhone (ACast 屏幕广播)\",\"ip\":\"\(myIp)\",\"port\":19999,\"model\":\"iPhone\",\"status\":\"capturing\"}"
                            Self.sendUdpBroadcast(message: beacon, broadcastIp: bcast, port: 19998)
                        }
                    }
                }
                Darwin.close(fd)
            }
        }
    }

    private func startExtensionDiscoveryBeacon() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self = self, self.isRunning {
                let (ip, bcast) = Self.getLocalWiFiAddressAndBroadcast()
                if !ip.isEmpty {
                    let beacon = "{\"cmd\":\"phone_beacon\",\"device_name\":\"iPhone (ACast 屏幕广播)\",\"ip\":\"\(ip)\",\"port\":19999,\"model\":\"iPhone\",\"status\":\"capturing\"}"
                    Self.sendUdpBroadcast(message: beacon, broadcastIp: bcast, port: 19998)
                }
                Thread.sleep(forTimeInterval: 2.0)
            }
        }
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

    static func getLocalWiFiAddressAndBroadcast() -> (String, String) {
        var address = ""
        var broadcast = "255.255.255.255"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return (address, broadcast)
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let addr = current.pointee.ifa_addr
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               let sa = addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ipStr = String(cString: hostname)
                    if !ipStr.hasPrefix("169.254.") && !ipStr.hasPrefix("127.") {
                        var bcastStr = "255.255.255.255"
                        if let netmask = current.pointee.ifa_netmask {
                            let ipIn = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                            let maskIn = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                            var bcastAddr = in_addr(s_addr: (ipIn & maskIn) | (~maskIn))
                            var bcastBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            if inet_ntop(AF_INET, &bcastAddr, &bcastBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                                bcastStr = String(cString: bcastBuf)
                            }
                        }
                        if name == "en0" || name == "bridge100" {
                            return (ipStr, bcastStr)
                        } else if address.isEmpty {
                            address = ipStr
                            broadcast = bcastStr
                        }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return (address, broadcast)
    }

    static func sendUdpBroadcast(message: String, broadcastIp: String, port: UInt16) {
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
            addr.sin_port = port.bigEndian
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
}

class SampleHandler: RPBroadcastSampleHandler {

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        NSLog("[ACast] iOS 屏幕广播推流已启动 (FastMirror 私有协议)")
        ExtensionFastMirrorBridge.shared.start()
    }

    override func broadcastPaused() {
        NSLog("[ACast] iOS 屏幕广播已暂停")
    }

    override func broadcastResumed() {
        NSLog("[ACast] iOS 屏幕广播已恢复")
    }

    override func broadcastFinished() {
        NSLog("[ACast] iOS 屏幕广播已结束")
        ExtensionFastMirrorBridge.shared.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            ExtensionFastMirrorBridge.shared.encodeVideoSampleBuffer(sampleBuffer)
        case .audioApp, .audioMic:
            break
        @unknown default:
            break
        }
    }
}
