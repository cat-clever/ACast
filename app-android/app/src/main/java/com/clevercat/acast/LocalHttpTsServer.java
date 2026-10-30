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

public class LocalHttpTsServer {

    private static final String TAG = "LocalHttpTsServer";
    private static final LocalHttpTsServer INSTANCE = new LocalHttpTsServer();

    public static LocalHttpTsServer getInstance() {
        return INSTANCE;
    }

    // TS 规范常量
    private static final byte TS_SYNC_BYTE = 0x47;
    private static final int TS_PID_PAT = 0x0000;
    private static final int TS_PID_PMT = 0x1000;
    private static final int TS_PID_VIDEO = 0x0100;
    private static final int TS_PID_AUDIO = 0x0101;

    // 连续性计数器 Continuity Counter (0~15)
    private int continuityPat = 0;
    private int continuityPmt = 0;
    private int continuityVideo = 0;
    private int continuityAudio = 0;

    private ServerSocket serverSocket;
    private volatile boolean isRunning = false;

    // 活跃的电视客户端会话列表
    private final CopyOnWriteArrayList<ClientSession> clientSessions = new CopyOnWriteArrayList<>();

    // 最新缓存的 SPS / PPS
    private byte[] cachedSpsPps = null;

    // GOP 环形缓存：保存最近一个完整关键帧及后续帧的 TS 包，电视连入时瞬间推送秒开
    private final List<byte[]> gopTsCache = Collections.synchronizedList(new ArrayList<>());
    private static final int MAX_GOP_CACHE_PACKETS = 600; // 约 100KB 数据，足够毫秒级起播

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

    public void startServer(int port) {
        if (isRunning) return;
        isRunning = true;

        new Thread(() -> {
            try {
                serverSocket = new ServerSocket(port);
                serverSocket.setReuseAddress(true);
                Log.i(TAG, "本地 MPEG-TS 实时流推流服务已启动，监听端口: " + port);

                while (isRunning) {
                    Socket client = serverSocket.accept();
                    client.setTcpNoDelay(true);
                    client.setSendBufferSize(256 * 1024);
                    Log.i(TAG, "智能电视客户端连入拉流: " + client.getRemoteSocketAddress());

                    new Thread(() -> handleHttpClient(client), "TsClientHandler").start();
                }
            } catch (Throwable e) {
                if (isRunning) {
                    Log.w(TAG, "MPEG-TS 监听循环退出: " + e.getMessage());
                }
            }
        }, "TsServerAcceptor").start();
    }

    private void handleHttpClient(Socket client) {
        ClientSession session = null;
        try {
            InputStream in = client.getInputStream();
            byte[] buf = new byte[2048];
            int read = in.read(buf);
            if (read <= 0) {
                try { client.close(); } catch (Throwable ignored) {}
                return;
            }

            String requestLine = "";
            boolean isHead = false;
            try {
                String reqStr = new String(buf, 0, read, "UTF-8");
                int firstLineEnd = reqStr.indexOf("\r\n");
                if (firstLineEnd > 0) {
                    requestLine = reqStr.substring(0, firstLineEnd);
                } else {
                    requestLine = reqStr;
                }
                if (requestLine.startsWith("HEAD")) {
                    isHead = true;
                }
            } catch (Throwable ignored) {}
            Log.i(TAG, "电视客户端请求拉流: " + requestLine + " (来自 " + client.getRemoteSocketAddress() + ")");

            OutputStream out = client.getOutputStream();
            // 响应标准 DLNA 实时直播流 HTTP Header (包含 streaming 扩展与特性声明)
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

            // 如果是探测性 HEAD 请求，发送完合法 Headers 后直接退出，绝不发送二进制 Body
            if (isHead) {
                Log.i(TAG, "HEAD 请求握手成功，等待电视后续拉流连接。");
                return;
            }

            // 电视正式连入拉流，立即请求硬件编码器即刻刷新全量关键帧 (IDR 帧)
            ScreenCaptureService.requestKeyFrame();

            session = new ClientSession(client, out);

            // 1. 先立即发送初始 PAT 与 PMT
            byte[] pat = generatePat();
            byte[] pmt = generatePmt();
            out.write(pat);
            out.write(pmt);
            out.flush();

            // 2. 爆发式推送已缓存的最近一个 GOP 数据（含 SPS/PPS 和完整关键帧），让电视瞬间填满缓冲区出画面
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
                    Log.i(TAG, "已向电视瞬间爆发推送 " + burstData.length + " 字节 GOP 首屏秒开数据");
                }
            }

            clientSessions.add(session);

            // 3. 持续消费待发送队列，并提供 40ms 高频 PCR 心跳守护（防止屏幕静止时电视 Demux PLL 失锁报 Operation Stopped）
            long lastPcrTimeMs = System.currentTimeMillis();
            while (isRunning && session.active && !client.isClosed()) {
                byte[] data = session.sendQueue.poll();
                if (data != null) {
                    out.write(data);
                    out.flush();
                    lastPcrTimeMs = System.currentTimeMillis();
                } else {
                    long now = System.currentTimeMillis();
                    if (now - lastPcrTimeMs >= 40) { // 超过 40ms 屏幕静止无帧，发送纯 PCR 时钟心跳包
                        byte[] pcrPacket = generatePcrPacket();
                        out.write(pcrPacket);
                        out.flush();
                        lastPcrTimeMs = now;
                    }
                    try {
                        Thread.sleep(10);
                    } catch (InterruptedException e) {
                        break;
                    }
                }
            }

        } catch (Throwable t) {
            Log.d(TAG, "电视客户端连接断开: " + t.getMessage());
        } finally {
            if (session != null) {
                clientSessions.remove(session);
                session.close();
            }
            try { client.close(); } catch (Throwable ignored) {}
        }
    }

    /**
     * 生成 188 字节的纯 PCR 时钟心跳包 (在画面静止无视频输出时维持电视时钟锁相环，杜绝超时断流)
     */
    private byte[] generatePcrPacket() {
        byte[] ts = new byte[188];
        Arrays.fill(ts, (byte) 0xFF);
        ts[0] = TS_SYNC_BYTE;
        ts[1] = (byte) ((TS_PID_VIDEO >> 8) & 0x1F);
        ts[2] = (byte) (TS_PID_VIDEO & 0xFF);
        ts[3] = 0x20; // 仅含 Adaptation Field，无 payload，continuity counter 保持不变
        ts[4] = (byte) 183; // adaptation length: 188 - 5 = 183
        ts[5] = 0x10; // PCR_flag = 1

        long pts90k = (System.currentTimeMillis() * 90); // 90kHz 时钟基准
        ts[6] = (byte) ((pts90k >> 25) & 0xFF);
        ts[7] = (byte) ((pts90k >> 17) & 0xFF);
        ts[8] = (byte) ((pts90k >> 9) & 0xFF);
        ts[9] = (byte) ((pts90k >> 1) & 0xFF);
        ts[10] = (byte) (((pts90k & 1) << 7) | 0x7E);
        ts[11] = 0x00;
        return ts;
    }

    public synchronized void setSpsPps(byte[] spsPps) {
        if (spsPps != null && spsPps.length > 0) {
            this.cachedSpsPps = spsPps.clone();
            Log.i(TAG, "已成功捕获并保存 SPS/PPS 配置信息 (" + spsPps.length + " bytes)");
        }
    }

    public void pushVideo(byte[] naluData, boolean isKeyFrame, long ptsUs) {
        if (!isRunning || naluData == null || naluData.length == 0) return;

        // 如果是关键帧且之前缓存了 SPS/PPS，而当前 NALU 开头未包含 SPS (0x67)，自动在帧前插入 SPS/PPS
        byte[] payloadToSend = naluData;
        if (isKeyFrame && cachedSpsPps != null && !containsSps(naluData)) {
            byte[] combined = new byte[cachedSpsPps.length + naluData.length];
            System.arraycopy(cachedSpsPps, 0, combined, 0, cachedSpsPps.length);
            System.arraycopy(naluData, 0, combined, cachedSpsPps.length, naluData.length);
            payloadToSend = combined;
        }

        // 关键帧前生成最新的 PAT 和 PMT 保证随切随播
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

        if (clientSessions.isEmpty()) return;

        // 合成单帧批量字节流提高 socket 发送效率
        int totalSize = tsPackets.size() * 188 + (pat != null ? 188 : 0) + (pmt != null ? 188 : 0);
        ByteArrayOutputStream frameStream = new ByteArrayOutputStream(totalSize);
        if (pat != null) frameStream.write(pat, 0, 188);
        if (pmt != null) frameStream.write(pmt, 0, 188);
        for (byte[] pkt : tsPackets) {
            frameStream.write(pkt, 0, 188);
        }
        byte[] frameBytes = frameStream.toByteArray();

        // 分发给各个电视会话
        for (ClientSession session : clientSessions) {
            if (!session.active) continue;

            // 首次接入需从关键帧开始投送
            if (!session.hasReceivedKeyFrame) {
                if (isKeyFrame) {
                    session.hasReceivedKeyFrame = true;
                } else {
                    continue; // 丢弃该 P 帧，直到遇到关键帧
                }
            }

            // 限制队列长度防止慢客户端导致内存溢出
            if (session.sendQueue.size() > 50) {
                session.sendQueue.poll();
            }
            session.sendQueue.offer(frameBytes);
        }
    }

    public void pushAudio(byte[] audioData, int size) {
        // 音频帧可选扩展
    }

    private boolean containsSps(byte[] data) {
        if (data.length < 5) return false;
        for (int i = 0; i < Math.min(data.length - 4, 64); i++) {
            if (data[i] == 0 && data[i + 1] == 0 && (data[i + 2] == 1 || (data[i + 2] == 0 && data[i + 3] == 1))) {
                int nalTypeIndex = (data[i + 2] == 1) ? (i + 3) : (i + 4);
                if (nalTypeIndex < data.length) {
                    int nalType = data[nalTypeIndex] & 0x1F;
                    if (nalType == 7) return true; // SPS
                }
            }
        }
        return false;
    }

    /**
     * 生成 188 字节标准 PAT 包
     */
    private byte[] generatePat() {
        byte[] packet = new byte[188];
        Arrays.fill(packet, (byte) 0xFF);
        packet[0] = TS_SYNC_BYTE;
        packet[1] = 0x40; // payload unit start indicator = 1, PID = 0x0000
        packet[2] = 0x00;
        packet[3] = (byte) (0x10 | (continuityPat++ & 0x0F));
        packet[4] = 0x00; // Pointer field

        // Table ID 0x00
        packet[5] = 0x00;
        packet[6] = (byte) 0xB0;
        packet[7] = 0x0D; // Section length: 13
        packet[8] = 0x00; packet[9] = 0x01; // Transport stream ID: 1
        packet[10] = (byte) 0xC1; // Version 0, current
        packet[11] = 0x00;
        packet[12] = 0x00;
        // Program 1 -> PMT PID 0x1000
        packet[13] = 0x00; packet[14] = 0x01;
        packet[15] = (byte) (0xE0 | ((TS_PID_PMT >> 8) & 0x1F));
        packet[16] = (byte) (TS_PID_PMT & 0xFF);

        // 标准 MPEG-2 CRC32 校验码
        int crc = calculateMpeg2Crc32(packet, 5, 12);
        packet[17] = (byte) ((crc >> 24) & 0xFF);
        packet[18] = (byte) ((crc >> 16) & 0xFF);
        packet[19] = (byte) ((crc >> 8) & 0xFF);
        packet[20] = (byte) (crc & 0xFF);
        return packet;
    }

    /**
     * 生成 188 字节标准 PMT 包 (包含 H.264 视频流 0x1B)
     */
    private byte[] generatePmt() {
        byte[] packet = new byte[188];
        Arrays.fill(packet, (byte) 0xFF);
        packet[0] = TS_SYNC_BYTE;
        packet[1] = (byte) (0x40 | ((TS_PID_PMT >> 8) & 0x1F));
        packet[2] = (byte) (TS_PID_PMT & 0xFF);
        packet[3] = (byte) (0x10 | (continuityPmt++ & 0x0F));
        packet[4] = 0x00; // Pointer field

        // Table ID 0x02
        packet[5] = 0x02;
        packet[6] = (byte) 0xB0;
        packet[7] = 0x17; // Section length: 23
        packet[8] = 0x00; packet[9] = 0x01; // Program number 1
        packet[10] = (byte) 0xC1;
        packet[11] = 0x00;
        packet[12] = 0x00;
        packet[13] = (byte) (0xE0 | ((TS_PID_VIDEO >> 8) & 0x1F)); // PCR PID
        packet[14] = (byte) (TS_PID_VIDEO & 0xFF);
        packet[15] = (byte) 0xF0; packet[16] = 0x00; // Program info length = 0

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

        // 标准 MPEG-2 CRC32 校验码
        int crc = calculateMpeg2Crc32(packet, 5, 22);
        packet[27] = (byte) ((crc >> 24) & 0xFF);
        packet[28] = (byte) ((crc >> 16) & 0xFF);
        packet[29] = (byte) ((crc >> 8) & 0xFF);
        packet[30] = (byte) (crc & 0xFF);
        return packet;
    }

    /**
     * 将 NALU 视频数据打包为标准 TS 包列表
     */
    private List<byte[]> packPesToTs(int pid, byte[] payload, long ptsUs, boolean isVideo, boolean isKeyFrame) {
        // Access Unit Delimiter (AUD)，H.264 规范定界符，提高各种大屏 Demuxer 兼容性
        byte[] aud = new byte[]{0x00, 0x00, 0x00, 0x01, 0x09, (byte) 0xF0};

        // 构造 PES 头
        int pesHeaderLen = 19;
        int totalPayloadLen = aud.length + payload.length;
        byte[] pes = new byte[pesHeaderLen + totalPayloadLen];

        // 0x000001
        pes[0] = 0x00; pes[1] = 0x00; pes[2] = 0x01;
        // Stream ID (0xE0 = Video)
        pes[3] = (byte) (isVideo ? 0xE0 : 0xC0);
        // PES length: 视频在 TS 中可设为 0 (unbounded)
        pes[4] = 0x00; pes[5] = 0x00;

        // Flags: PTS present
        pes[6] = (byte) 0x80;
        pes[7] = (byte) 0x80; // PTS_flags = 2
        pes[8] = 0x05; // Header data length = 5

        // 33-bit PTS (90kHz)
        long pts90k = (ptsUs * 9) / 100;
        pes[9]  = (byte) (0x21 | (((pts90k >> 30) & 0x07) << 1));
        pes[10] = (byte) ((pts90k >> 22) & 0xFF);
        pes[11] = (byte) (0x01 | (((pts90k >> 15) & 0x7F) << 1));
        pes[12] = (byte) ((pts90k >> 7) & 0xFF);
        pes[13] = (byte) (0x01 | ((pts90k & 0x7F) << 1));

        // 复制 AUD 与 NALU 数据
        System.arraycopy(aud, 0, pes, pesHeaderLen, aud.length);
        System.arraycopy(payload, 0, pes, pesHeaderLen + aud.length, payload.length);

        // 切割装入 188 字节 TS 包
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

            // 首包如果是关键帧，嵌入 PCR (Program Clock Reference) 时钟基准
            if (isFirst && isKeyFrame) {
                ts[3] |= 0x20; // 包含 Adaptation Field
                ts[4] = 0x07; // Adaptation length: 7 bytes (1 flag + 6 PCR)
                ts[5] = 0x10; // PCR flag = 1
                // 写入 6 字节 PCR
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
                // 末尾包不足 188 字节，填充 Adaptation Field Stuffing
                int stuffingLen = availablePayload - remaining;
                if ((ts[3] & 0x20) == 0) {
                    // 原先无 adaptation field
                    ts[3] |= 0x20;
                    ts[headerLen] = (byte) (stuffingLen - 1);
                    if (stuffingLen > 1) {
                        ts[headerLen + 1] = 0x00; // flags
                        Arrays.fill(ts, headerLen + 2, headerLen + stuffingLen, (byte) 0xFF);
                    }
                    headerLen += stuffingLen;
                } else {
                    // 已有 adaptation field，追加填充
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

    /**
     * 计算 MPEG-2 标准 CRC32 (多项式 0x04C11DB7, 初始 0xFFFFFFFF)
     */
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

    public void stopServer() {
        isRunning = false;
        try {
            if (serverSocket != null) serverSocket.close();
        } catch (Throwable ignored) {}
        for (ClientSession session : clientSessions) {
            session.close();
        }
        clientSessions.clear();
        synchronized (gopTsCache) {
            gopTsCache.clear();
        }
    }
}
