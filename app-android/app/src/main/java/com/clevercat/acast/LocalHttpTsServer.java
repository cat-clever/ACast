package com.clevercat.acast;

import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 本地高性能 HTTP 实时流媒体服务器 (端口 8088)
 *
 * 核心架构升级：
 * 1. 【双通道彻底隔离 (Screen & Camera)】：
 *    - 屏幕投屏通道 (/screen, /screen.ts)：专属手机屏幕画面，绝不混入摄像头；
 *    - 摄像头通道 (/camera, /camera.ts)：专属高清摄像头画面，绝不混入屏幕投屏；
 *    - 通用通道 (/live, /live.ts)：根据当前活跃流智能路由，彻底根治画面交错混流 (Cross-feed) 现象。
 *
 * 2. 【超低延迟直连传输 (HTTP-TS Chunked Stream)】：
 *    - 针对 /live, /camera, /screen，默认直接建立持续的 MPEG-TS 字节长连接；
 *    - 配合 TCP_NODELAY 与关键帧首屏 GOP 瞬间秒开机制，延迟由 HLS 的 2~5 秒降至 50ms~100ms；
 *    - 仅在客户端显式请求 .m3u8 时才走切片清单模式，兼顾大屏 DLNA 与 OBS 超低延迟拉流。
 */
public class LocalHttpTsServer {

    private static final String TAG = "LocalHttpTsServer";
    private static final LocalHttpTsServer INSTANCE = new LocalHttpTsServer();

    public static LocalHttpTsServer getInstance() {
        return INSTANCE;
    }

    // TS 规范基础常量
    private static final byte TS_SYNC_BYTE = 0x47;
    private static final int TS_PID_PAT = 0x0000;
    private static final int TS_PID_PMT = 0x1000;
    private static final int TS_PID_VIDEO = 0x0100;
    private static final int TS_PID_AUDIO = 0x0101;

    // 独立通道实例
    private final StreamChannel screenChannel = new StreamChannel("screen");
    private final StreamChannel cameraChannel = new StreamChannel("camera");

    private ServerSocket serverSocket;
    private volatile boolean isRunning = false;

    public StreamChannel getScreenChannel() {
        return screenChannel;
    }

    public StreamChannel getCameraChannel() {
        return cameraChannel;
    }

    // ==================== HLS 分片载荷结构 ====================
    public static class HlsSegment {
        final long sequence;
        final double durationSec;
        final byte[] tsData;

        public HlsSegment(long sequence, double durationSec, byte[] tsData) {
            this.sequence = sequence;
            this.durationSec = durationSec;
            this.tsData = tsData;
        }
    }

    // ==================== 长连接客户端会话 ====================
    private static class ClientSession {
        final Socket socket;
        final OutputStream out;
        volatile boolean active = true;
        volatile boolean hasReceivedKeyFrame = false;
        final ConcurrentLinkedQueue<byte[]> sendQueue = new ConcurrentLinkedQueue<>();

        ClientSession(Socket socket, OutputStream out) {
            this.socket = socket;
            this.out = out;
        }

        void close() {
            active = false;
            try { socket.close(); } catch (Throwable ignored) {}
        }
    }

    /**
     * 单个独立的推流通道 (拥有完全隔离的编码配置、GOP 秒开缓存、会话队列与连续性计数器)
     */
    public static class StreamChannel {
        private final String name;
        private int continuityPat = 0;
        private int continuityPmt = 0;
        private int continuityVideo = 0;
        private byte[] cachedSpsPps = null;

        // GOP 秒开环形缓存 (缓存最近一个完整关键帧及其后续帧)
        private final List<byte[]> gopTsCache = Collections.synchronizedList(new ArrayList<>());
        private static final int MAX_GOP_CACHE_PACKETS = 600;

        // HLS 切片状态
        private final Object hlsLock = new Object();
        private final List<HlsSegment> hlsSegments = new ArrayList<>();
        private static final int MAX_HLS_SEGMENTS = 4;
        private long segmentSequenceCounter = 1;
        private final ByteArrayOutputStream currentSegmentBuffer = new ByteArrayOutputStream(256 * 1024);
        private long currentSegmentStartPtsUs = -1;
        private long currentSegmentLastPtsUs = -1;

        // 活跃长连接会话
        private final CopyOnWriteArrayList<ClientSession> clientSessions = new CopyOnWriteArrayList<>();
        private volatile long lastFrameTimestampMs = 0;

        public StreamChannel(String name) {
            this.name = name;
        }

        public String getName() {
            return name;
        }

        public boolean isActivelyStreaming() {
            return (System.currentTimeMillis() - lastFrameTimestampMs) < 2500;
        }

        public synchronized void setSpsPps(byte[] spsPps) {
            if (spsPps != null && spsPps.length > 0) {
                this.cachedSpsPps = spsPps.clone();
                Log.i(TAG, "[" + name + "] 成功配置专属 SPS/PPS (" + spsPps.length + " bytes)");
            }
        }

        public void pushVideo(byte[] naluData, boolean isKeyFrame, long ptsUs) {
            if (naluData == null || naluData.length == 0) return;
            lastFrameTimestampMs = System.currentTimeMillis();

            // 若为关键帧且当前 NALU 开头未携带 SPS，自动补齐头部 SPS/PPS
            byte[] payloadToSend = naluData;
            if (isKeyFrame && cachedSpsPps != null && !containsSps(naluData)) {
                byte[] combined = new byte[cachedSpsPps.length + naluData.length];
                System.arraycopy(cachedSpsPps, 0, combined, 0, cachedSpsPps.length);
                System.arraycopy(naluData, 0, combined, cachedSpsPps.length, naluData.length);
                payloadToSend = combined;
            }

            byte[] pat = null;
            byte[] pmt = null;
            if (isKeyFrame) {
                pat = generatePat();
                pmt = generatePmt();
            }

            // 打包 PES -> TS
            List<byte[]> tsPackets = packPesToTs(TS_PID_VIDEO, payloadToSend, ptsUs, true, isKeyFrame);

            // 更新 GOP 秒开缓存
            if (isKeyFrame) {
                synchronized (gopTsCache) {
                    gopTsCache.clear();
                    if (pat != null) gopTsCache.add(pat);
                    if (pmt != null) gopTsCache.add(pmt);
                    gopTsCache.addAll(tsPackets);
                }
            } else {
                synchronized (gopTsCache) {
                    if (gopTsCache.size() < MAX_GOP_CACHE_PACKETS) {
                        gopTsCache.addAll(tsPackets);
                    }
                }
            }

            // 合成当前帧字节数据
            int totalSize = tsPackets.size() * 188 + (pat != null ? 188 : 0) + (pmt != null ? 188 : 0);
            ByteArrayOutputStream frameStream = new ByteArrayOutputStream(totalSize);
            if (pat != null) frameStream.write(pat, 0, 188);
            if (pmt != null) frameStream.write(pmt, 0, 188);
            for (byte[] pkt : tsPackets) {
                frameStream.write(pkt, 0, 188);
            }
            byte[] frameBytes = frameStream.toByteArray();

            // 1. 追加到 HLS 内存分片切片器 (供 M3U8 客户端拉取)
            appendHlsFrame(frameBytes, isKeyFrame, ptsUs);

            // 2. 超低延迟实时推送至各个长连接客户端 (供 OBS、VLC 等实时流)
            if (!clientSessions.isEmpty()) {
                for (ClientSession session : clientSessions) {
                    if (!session.active) continue;
                    if (!session.hasReceivedKeyFrame) {
                        if (isKeyFrame) {
                            session.hasReceivedKeyFrame = true;
                        } else {
                            continue;
                        }
                    }
                    if (session.sendQueue.size() > 30) {
                        session.sendQueue.poll();
                    }
                    session.sendQueue.offer(frameBytes);
                }
            }
        }

        private void appendHlsFrame(byte[] frameBytes, boolean isKeyFrame, long ptsUs) {
            synchronized (hlsLock) {
                if (isKeyFrame) {
                    if (currentSegmentStartPtsUs > 0 && currentSegmentBuffer.size() > 0) {
                        long durationUs = ptsUs - currentSegmentStartPtsUs;
                        if (durationUs >= 350_000L || currentSegmentBuffer.size() >= 80 * 1024) {
                            double durSec = Math.max(0.3, durationUs / 1_000_000.0);
                            byte[] segData = currentSegmentBuffer.toByteArray();
                            hlsSegments.add(new HlsSegment(segmentSequenceCounter++, durSec, segData));
                            if (hlsSegments.size() > MAX_HLS_SEGMENTS) {
                                hlsSegments.remove(0);
                            }
                            currentSegmentBuffer.reset();
                            hlsLock.notifyAll();
                        }
                    }
                    if (currentSegmentBuffer.size() == 0) {
                        currentSegmentStartPtsUs = ptsUs;
                    }
                }
                if (currentSegmentStartPtsUs > 0) {
                    currentSegmentBuffer.write(frameBytes, 0, frameBytes.length);
                    currentSegmentLastPtsUs = ptsUs;
                }
            }
        }

        public void handleLiveTsLongPoll(Socket client, String method, OutputStream out) {
            ClientSession session = null;
            try {
                boolean isHead = "HEAD".equals(method);
                String responseHeader =
                        "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: video/mp2t\r\n" +
                        "Connection: keep-alive\r\n" +
                        "Accept-Ranges: none\r\n" +
                        "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
                        "Pragma: no-cache\r\n" +
                        "Expires: 0\r\n" +
                        "Access-Control-Allow-Origin: *\r\n" +
                        "transferMode.dlna.org: Streaming\r\n" +
                        "contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n" +
                        "ext:\r\n\r\n";
                out.write(responseHeader.getBytes("UTF-8"));
                out.flush();

                if (isHead) return;

                // 若为屏幕通道，尝试请求关键帧刷新
                if ("screen".equals(name)) {
                    ScreenCaptureService.requestKeyFrame();
                }

                session = new ClientSession(client, out);

                // 立即发送初始 PAT 与 PMT
                byte[] pat = generatePat();
                byte[] pmt = generatePmt();
                out.write(pat);
                out.write(pmt);
                out.flush();

                // 瞬间爆发推送 GOP 首屏缓存数据，实现零黑屏秒开
                synchronized (gopTsCache) {
                    if (!gopTsCache.isEmpty()) {
                        ByteArrayOutputStream gopBuf = new ByteArrayOutputStream(gopTsCache.size() * 188);
                        for (byte[] pkt : gopTsCache) {
                            gopBuf.write(pkt);
                        }
                        byte[] burstData = gopBuf.toByteArray();
                        out.write(burstData);
                        out.flush();
                        session.hasReceivedKeyFrame = true;
                    }
                }

                clientSessions.add(session);

                // 持续消费推流队列，40ms PCR 心跳锁相环
                long lastPcrTimeMs = System.currentTimeMillis();
                while (session.active && !client.isClosed()) {
                    byte[] data = session.sendQueue.poll();
                    if (data != null) {
                        out.write(data);
                        out.flush();
                        lastPcrTimeMs = System.currentTimeMillis();
                    } else {
                        long now = System.currentTimeMillis();
                        if (now - lastPcrTimeMs >= 40) {
                            byte[] pcrPacket = generatePcrPacket();
                            out.write(pcrPacket);
                            out.flush();
                            lastPcrTimeMs = now;
                        }
                        try {
                            Thread.sleep(8);
                        } catch (InterruptedException e) {
                            break;
                        }
                    }
                }

            } catch (Throwable t) {
                // 连接正常断开
            } finally {
                if (session != null) {
                    clientSessions.remove(session);
                    session.close();
                }
                try { client.close(); } catch (Throwable ignored) {}
            }
        }

        public void handleM3u8Request(Socket client, String method, OutputStream out) {
            try {
                synchronized (hlsLock) {
                    if (hlsSegments.isEmpty()) {
                        if ("screen".equals(name)) {
                            ScreenCaptureService.requestKeyFrame();
                        }
                        try {
                            hlsLock.wait(600);
                        } catch (InterruptedException ignored) {}
                    }
                    if (hlsSegments.isEmpty() && currentSegmentBuffer.size() > 0) {
                        long durationUs = Math.max(300_000L, currentSegmentLastPtsUs - currentSegmentStartPtsUs);
                        double durSec = Math.max(0.3, durationUs / 1_000_000.0);
                        byte[] segData = currentSegmentBuffer.toByteArray();
                        hlsSegments.add(new HlsSegment(segmentSequenceCounter++, durSec, segData));
                        currentSegmentBuffer.reset();
                        currentSegmentStartPtsUs = -1;
                    }
                    if (hlsSegments.isEmpty()) {
                        ensureStandbySegmentLocked();
                    }
                }

                String playlist = generateM3u8Playlist();
                byte[] body = playlist.getBytes("UTF-8");
                String header =
                        "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: application/vnd.apple.mpegurl\r\n" +
                        "Content-Length: " + body.length + "\r\n" +
                        "Connection: close\r\n" +
                        "Access-Control-Allow-Origin: *\r\n" +
                        "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
                        "Pragma: no-cache\r\n" +
                        "Expires: 0\r\n\r\n";
                out.write(header.getBytes("UTF-8"));
                if (!"HEAD".equals(method)) {
                    out.write(body);
                }
                out.flush();
            } catch (Throwable t) {
                Log.w(TAG, "[" + name + "] 输出 M3U8 清单异常: " + t.getMessage());
            } finally {
                try { client.close(); } catch (Throwable ignored) {}
            }
        }

        private void ensureStandbySegmentLocked() {
            if (!hlsSegments.isEmpty()) return;
            ByteArrayOutputStream baos = new ByteArrayOutputStream(188 * 3);
            byte[] pat = generatePat();
            byte[] pmt = generatePmt();
            byte[] pcr = generatePcrPacket();
            baos.write(pat, 0, 188);
            baos.write(pmt, 0, 188);
            baos.write(pcr, 0, 188);
            hlsSegments.add(new HlsSegment(segmentSequenceCounter++, 1.0, baos.toByteArray()));
        }

        public void handleSegmentRequest(Socket client, String method, String path, OutputStream out) {
            try {
                long seq = -1;
                int segIdx = path.indexOf("segment-");
                int dotIdx = path.indexOf(".ts", segIdx);
                if (segIdx >= 0 && dotIdx > segIdx) {
                    String numStr = path.substring(segIdx + "segment-".length(), dotIdx);
                    try {
                        seq = Long.parseLong(numStr);
                    } catch (Throwable ignored) {}
                }

                byte[] segData = null;
                synchronized (hlsLock) {
                    for (HlsSegment seg : hlsSegments) {
                        if (seg.sequence == seq) {
                            segData = seg.tsData;
                            break;
                        }
                    }
                }

                if (segData != null) {
                    String header =
                            "HTTP/1.1 200 OK\r\n" +
                            "Content-Type: video/mp2t\r\n" +
                            "Content-Length: " + segData.length + "\r\n" +
                            "Connection: close\r\n" +
                            "Access-Control-Allow-Origin: *\r\n" +
                            "Cache-Control: public, max-age=86400\r\n\r\n";
                    out.write(header.getBytes("UTF-8"));
                    if (!"HEAD".equals(method)) {
                        out.write(segData);
                    }
                    out.flush();
                } else {
                    String header = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    out.write(header.getBytes("UTF-8"));
                    out.flush();
                }
            } catch (Throwable t) {
                Log.w(TAG, "[" + name + "] 输出 Segment 异常: " + t.getMessage());
            } finally {
                try { client.close(); } catch (Throwable ignored) {}
            }
        }

        private String generateM3u8Playlist() {
            synchronized (hlsLock) {
                if (hlsSegments.isEmpty()) {
                    return "#EXTM3U\n" +
                            "#EXT-X-VERSION:3\n" +
                            "#EXT-X-TARGETDURATION:2\n" +
                            "#EXT-X-MEDIA-SEQUENCE:1\n";
                }
                long mediaSequence = hlsSegments.get(0).sequence;
                int targetDuration = 2;
                for (HlsSegment seg : hlsSegments) {
                    int rounded = (int) Math.ceil(seg.durationSec);
                    if (rounded > targetDuration) {
                        targetDuration = rounded;
                    }
                }

                StringBuilder sb = new StringBuilder();
                sb.append("#EXTM3U\n");
                sb.append("#EXT-X-VERSION:3\n");
                sb.append("#EXT-X-TARGETDURATION:").append(targetDuration).append("\n");
                sb.append("#EXT-X-MEDIA-SEQUENCE:").append(mediaSequence).append("\n");

                for (HlsSegment seg : hlsSegments) {
                    sb.append(String.format(java.util.Locale.US, "#EXTINF:%.3f,\n", seg.durationSec));
                    sb.append(name).append("-segment-").append(seg.sequence).append(".ts\n");
                }
                return sb.toString();
            }
        }

        public void reset() {
            cachedSpsPps = null;
            synchronized (gopTsCache) {
                gopTsCache.clear();
            }
            for (ClientSession session : clientSessions) {
                session.close();
            }
            clientSessions.clear();
            synchronized (hlsLock) {
                hlsSegments.clear();
                currentSegmentBuffer.reset();
                currentSegmentStartPtsUs = -1;
                currentSegmentLastPtsUs = -1;
                hlsLock.notifyAll();
            }
        }

        // ==================== TS 封装辅助方法 ====================
        private byte[] generatePat() {
            byte[] packet = new byte[188];
            Arrays.fill(packet, (byte) 0xFF);
            packet[0] = TS_SYNC_BYTE;
            packet[1] = 0x40;
            packet[2] = 0x00;
            packet[3] = (byte) (0x10 | (continuityPat++ & 0x0F));
            packet[4] = 0x00;
            packet[5] = 0x00;
            packet[6] = (byte) 0xB0;
            packet[7] = 0x0D;
            packet[8] = 0x00; packet[9] = 0x01;
            packet[10] = (byte) 0xC1;
            packet[11] = 0x00;
            packet[12] = 0x00;
            packet[13] = 0x00; packet[14] = 0x01;
            packet[15] = (byte) (0xE0 | ((TS_PID_PMT >> 8) & 0x1F));
            packet[16] = (byte) (TS_PID_PMT & 0xFF);

            int crc = calculateMpeg2Crc32(packet, 5, 12);
            packet[17] = (byte) ((crc >> 24) & 0xFF);
            packet[18] = (byte) ((crc >> 16) & 0xFF);
            packet[19] = (byte) ((crc >> 8) & 0xFF);
            packet[20] = (byte) (crc & 0xFF);
            return packet;
        }

        private byte[] generatePmt() {
            byte[] packet = new byte[188];
            Arrays.fill(packet, (byte) 0xFF);
            packet[0] = TS_SYNC_BYTE;
            packet[1] = (byte) (0x40 | ((TS_PID_PMT >> 8) & 0x1F));
            packet[2] = (byte) (TS_PID_PMT & 0xFF);
            packet[3] = (byte) (0x10 | (continuityPmt++ & 0x0F));
            packet[4] = 0x00;
            packet[5] = 0x02;
            packet[6] = (byte) 0xB0;
            packet[7] = 0x17;
            packet[8] = 0x00; packet[9] = 0x01;
            packet[10] = (byte) 0xC1;
            packet[11] = 0x00;
            packet[12] = 0x00;
            packet[13] = (byte) (0xE0 | ((TS_PID_VIDEO >> 8) & 0x1F));
            packet[14] = (byte) (TS_PID_VIDEO & 0xFF);
            packet[15] = (byte) 0xF0; packet[16] = 0x00;

            // Stream 1: H.264 Video (0x1B)
            packet[17] = 0x1B;
            packet[18] = (byte) (0xE0 | ((TS_PID_VIDEO >> 8) & 0x1F));
            packet[19] = (byte) (TS_PID_VIDEO & 0xFF);
            packet[20] = (byte) 0xF0; packet[21] = 0x00;

            // Stream 2: AAC Audio (0x0F)
            packet[22] = 0x0F;
            packet[23] = (byte) (0xE0 | ((TS_PID_AUDIO >> 8) & 0x1F));
            packet[24] = (byte) (TS_PID_AUDIO & 0xFF);
            packet[25] = (byte) 0xF0; packet[26] = 0x00;

            int crc = calculateMpeg2Crc32(packet, 5, 22);
            packet[27] = (byte) ((crc >> 24) & 0xFF);
            packet[28] = (byte) ((crc >> 16) & 0xFF);
            packet[29] = (byte) ((crc >> 8) & 0xFF);
            packet[30] = (byte) (crc & 0xFF);
            return packet;
        }

        private byte[] generatePcrPacket() {
            byte[] ts = new byte[188];
            Arrays.fill(ts, (byte) 0xFF);
            ts[0] = TS_SYNC_BYTE;
            ts[1] = (byte) ((TS_PID_VIDEO >> 8) & 0x1F);
            ts[2] = (byte) (TS_PID_VIDEO & 0xFF);
            ts[3] = 0x20;
            ts[4] = (byte) 183;
            ts[5] = 0x10;

            long pts90k = (System.currentTimeMillis() * 90);
            ts[6] = (byte) ((pts90k >> 25) & 0xFF);
            ts[7] = (byte) ((pts90k >> 17) & 0xFF);
            ts[8] = (byte) ((pts90k >> 9) & 0xFF);
            ts[9] = (byte) ((pts90k >> 1) & 0xFF);
            ts[10] = (byte) (((pts90k & 1) << 7) | 0x7E);
            ts[11] = 0x00;
            return ts;
        }

        private List<byte[]> packPesToTs(int pid, byte[] payload, long ptsUs, boolean isVideo, boolean isKeyFrame) {
            byte[] aud = new byte[]{0x00, 0x00, 0x00, 0x01, 0x09, (byte) 0xF0};
            int pesHeaderLen = 19;
            int totalPayloadLen = aud.length + payload.length;
            byte[] pes = new byte[pesHeaderLen + totalPayloadLen];

            pes[0] = 0x00; pes[1] = 0x00; pes[2] = 0x01;
            pes[3] = (byte) (isVideo ? 0xE0 : 0xC0);
            pes[4] = 0x00; pes[5] = 0x00;
            pes[6] = (byte) 0x80;
            pes[7] = (byte) 0x80;
            pes[8] = 0x05;

            long pts90k = (ptsUs * 9) / 100;
            pes[9]  = (byte) (0x21 | (((pts90k >> 30) & 0x07) << 1));
            pes[10] = (byte) ((pts90k >> 22) & 0xFF);
            pes[11] = (byte) (0x01 | (((pts90k >> 15) & 0x7F) << 1));
            pes[12] = (byte) ((pts90k >> 7) & 0xFF);
            pes[13] = (byte) (0x01 | ((pts90k & 0x7F) << 1));

            System.arraycopy(aud, 0, pes, pesHeaderLen, aud.length);
            System.arraycopy(payload, 0, pes, pesHeaderLen + aud.length, payload.length);

            List<byte[]> result = new ArrayList<>();
            int offset = 0;
            boolean isFirst = true;

            while (offset < pes.length) {
                byte[] ts = new byte[188];
                Arrays.fill(ts, (byte) 0xFF);
                ts[0] = TS_SYNC_BYTE;
                ts[1] = (byte) ((isFirst ? 0x40 : 0x00) | ((pid >> 8) & 0x1F));
                ts[2] = (byte) (pid & 0xFF);
                ts[3] = (byte) (0x10 | (continuityVideo++ & 0x0F));

                int headerLen = 4;
                int remaining = pes.length - offset;

                if (isFirst && isKeyFrame) {
                    ts[3] |= 0x20;
                    ts[4] = 0x07;
                    ts[5] = 0x10;
                    long pcrBase = pts90k;
                    ts[6] = (byte) ((pcrBase >> 25) & 0xFF);
                    ts[7] = (byte) ((pcrBase >> 17) & 0xFF);
                    ts[8] = (byte) ((pcrBase >> 9) & 0xFF);
                    ts[9] = (byte) ((pcrBase >> 1) & 0xFF);
                    ts[10] = (byte) (((pcrBase & 1) << 7) | 0x7E);
                    ts[11] = 0x00;
                    headerLen += 8;
                }

                int availablePayload = 188 - headerLen;
                if (remaining < availablePayload) {
                    int stuffingLen = availablePayload - remaining;
                    if ((ts[3] & 0x20) == 0) {
                        ts[3] |= 0x20;
                        ts[headerLen] = (byte) (stuffingLen - 1);
                        if (stuffingLen > 1) {
                            ts[headerLen + 1] = 0x00;
                            Arrays.fill(ts, headerLen + 2, headerLen + stuffingLen, (byte) 0xFF);
                        }
                        headerLen += stuffingLen;
                    } else {
                        int currentAdaptLen = ts[4] & 0xFF;
                        int newAdaptLen = currentAdaptLen + stuffingLen;
                        ts[4] = (byte) newAdaptLen;
                        Arrays.fill(ts, headerLen, headerLen + stuffingLen, (byte) 0xFF);
                        headerLen += stuffingLen;
                    }
                }

                int toCopy = 188 - headerLen;
                if (toCopy > 0) {
                    System.arraycopy(pes, offset, ts, headerLen, toCopy);
                    offset += toCopy;
                }
                isFirst = false;
                result.add(ts);
            }
            return result;
        }

        private boolean containsSps(byte[] data) {
            if (data.length < 5) return false;
            for (int i = 0; i < Math.min(data.length - 4, 64); i++) {
                if (data[i] == 0 && data[i + 1] == 0 && (data[i + 2] == 1 || (data[i + 2] == 0 && data[i + 3] == 1))) {
                    int nalTypeIndex = (data[i + 2] == 1) ? (i + 3) : (i + 4);
                    if (nalTypeIndex < data.length) {
                        int nalType = data[nalTypeIndex] & 0x1F;
                        if (nalType == 7) return true;
                    }
                }
            }
            return false;
        }
    }

    // ==================== 全局生命周期与 HTTP 服务端 ====================

    public synchronized void startServer(int port) {
        if (isRunning && serverSocket != null && !serverSocket.isClosed()) return;
        isRunning = true;

        new Thread(() -> {
            try {
                if (serverSocket != null && !serverSocket.isClosed()) {
                    try { serverSocket.close(); } catch (Throwable ignored) {}
                }
                serverSocket = new ServerSocket();
                serverSocket.setReuseAddress(true);
                serverSocket.bind(new java.net.InetSocketAddress(port));
                Log.i(TAG, "✓ 本地 HTTP 独立多通道实时流媒体服务器已启动，监听端口: " + port);

                while (isRunning && !serverSocket.isClosed()) {
                    Socket client = serverSocket.accept();
                    client.setTcpNoDelay(true);
                    client.setSendBufferSize(256 * 1024);

                    new Thread(() -> handleHttpClient(client), "TsClientHandler").start();
                }
            } catch (Throwable e) {
                if (isRunning) {
                    Log.w(TAG, "MPEG-TS 监听循环异常: " + e.getMessage());
                }
            } finally {
                isRunning = false;
            }
        }, "TsServerAcceptor").start();
    }

    public synchronized void stopServer() {
        isRunning = false;
        try {
            if (serverSocket != null && !serverSocket.isClosed()) {
                serverSocket.close();
            }
        } catch (Throwable ignored) {}
        serverSocket = null;
        screenChannel.reset();
        cameraChannel.reset();
    }

    private void handleHttpClient(Socket client) {
        try {
            InputStream in = client.getInputStream();
            byte[] buf = new byte[2048];
            int read = in.read(buf);
            if (read <= 0) {
                try { client.close(); } catch (Throwable ignored) {}
                return;
            }

            String requestLine = "";
            try {
                String reqStr = new String(buf, 0, read, "UTF-8");
                int firstLineEnd = reqStr.indexOf("\r\n");
                requestLine = (firstLineEnd > 0) ? reqStr.substring(0, firstLineEnd) : reqStr;
            } catch (Throwable ignored) {}

            String method = "GET";
            String path = "/";
            String[] parts = requestLine.split(" ");
            if (parts.length >= 2) {
                method = parts[0].toUpperCase(java.util.Locale.US);
                path = parts[1];
            }

            Log.i(TAG, "客户端 HTTP 请求: " + method + " " + path + " (来自 " + client.getRemoteSocketAddress() + ")");

            OutputStream out = client.getOutputStream();

            // 处理 OPTIONS 预检请求
            if ("OPTIONS".equals(method)) {
                String optionsResp =
                        "HTTP/1.1 204 No Content\r\n" +
                        "Access-Control-Allow-Origin: *\r\n" +
                        "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n" +
                        "Access-Control-Allow-Headers: *\r\n" +
                        "Content-Length: 0\r\n" +
                        "Connection: close\r\n\r\n";
                out.write(optionsResp.getBytes("UTF-8"));
                out.flush();
                try { client.close(); } catch (Throwable ignored) {}
                return;
            }

            // 清理 URL 查询参数
            int qIdx = path.indexOf('?');
            String cleanPath = (qIdx >= 0) ? path.substring(0, qIdx) : path;

            // 1. 严格多通道匹配路由 (Screen & Camera 独立隔离)
            StreamChannel targetChannel;
            if (cleanPath.startsWith("/camera")) {
                targetChannel = cameraChannel;
            } else if (cleanPath.startsWith("/screen")) {
                targetChannel = screenChannel;
            } else {
                // 默认 /live 或 /
                // 智能感知：若摄像头正处于推流活跃状态，且屏幕未活跃，优先输出摄像头流
                if (cameraChannel.isActivelyStreaming() && !screenChannel.isActivelyStreaming()) {
                    targetChannel = cameraChannel;
                } else {
                    targetChannel = screenChannel;
                }
            }

            // 2. 协议模式分配
            // HLS 分片请求 (例如 camera-segment-1.ts 或 segment-1.ts)
            if (cleanPath.contains("segment-") && cleanPath.endsWith(".ts")) {
                targetChannel.handleSegmentRequest(client, method, cleanPath, out);
                return;
            }

            // 仅在明确请求 .m3u8 时才输出 HLS 清单
            if (cleanPath.endsWith(".m3u8")) {
                targetChannel.handleM3u8Request(client, method, out);
                return;
            }

            // 默认对 /live, /camera, /screen 以及 .ts 长连接：直接启用超低延迟持续 MPEG-TS 推流！
            // 延迟彻底降至 50ms~100ms 毫秒级，彻底消除切片等待
            targetChannel.handleLiveTsLongPoll(client, method, out);

        } catch (Throwable t) {
            Log.d(TAG, "处理客户端连接失败: " + t.getMessage());
            try { client.close(); } catch (Throwable ignored) {}
        }
    }

    // 兼容既有全局调用接口 (默认转发至屏幕通道)
    public synchronized void setSpsPps(byte[] spsPps) {
        screenChannel.setSpsPps(spsPps);
    }

    public void pushVideo(byte[] naluData, boolean isKeyFrame, long ptsUs) {
        screenChannel.pushVideo(naluData, isKeyFrame, ptsUs);
    }

    public void pushAudio(byte[] audioData, int size) {
        // 音频可选扩展
    }

    private static int calculateMpeg2Crc32(byte[] data, int offset, int length) {
        int crc = 0xFFFFFFFF;
        for (int i = 0; i < length; i++) {
            crc ^= ((data[offset + i] & 0xFF) << 24);
            for (int j = 0; j < 8; j++) {
                if ((crc & 0x80000000) != 0) {
                    crc = (crc << 1) ^ 0x04C11DB7;
                } else {
                    crc = crc << 1;
                }
            }
        }
        return crc;
    }
}
