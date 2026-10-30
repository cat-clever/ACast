package com.clevercat.acast;

import android.util.Log;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.CopyOnWriteArrayList;

public class FastMirrorSender {

    private static final String TAG = "FastMirrorSender";
    private static final short MAGIC = (short) 0x4D46; // "FM"

    private static final byte MSG_VIDEO_FRAME = 0x06;
    private static final byte MSG_AUDIO_FRAME = 0x07;
    private static final byte MSG_TOUCH_DOWN = 0x10;
    private static final byte MSG_TOUCH_MOVE = 0x11;
    private static final byte MSG_TOUCH_UP = 0x12;
    private static final byte MSG_KEY_DOWN = 0x20;
    private static final byte MSG_TEXT_INPUT = 0x22;

    private static final FastMirrorSender INSTANCE = new FastMirrorSender();

    public static FastMirrorSender getInstance() {
        return INSTANCE;
    }

    private ServerSocket serverSocket;
    private volatile boolean isRunning = false;
    private Thread serverThread;
    private final CopyOnWriteArrayList<Socket> clientSockets = new CopyOnWriteArrayList<>();
    private byte[] cachedSpsPps = null;

    public synchronized void startServer(int port) {
        if (isRunning && serverSocket != null && !serverSocket.isClosed()) return;
        isRunning = true;

        serverThread = new Thread(() -> {
            try {
                if (serverSocket != null && !serverSocket.isClosed()) {
                    try { serverSocket.close(); } catch (Throwable ignored) {}
                }
                serverSocket = new ServerSocket();
                serverSocket.setReuseAddress(true);
                serverSocket.bind(new java.net.InetSocketAddress(port));
                Log.i(TAG, "FastMirror 投屏与反控服务已就绪，监听端口: " + port);

                while (isRunning && !serverSocket.isClosed()) {
                    Socket client = serverSocket.accept();
                    client.setTcpNoDelay(true);
                    client.setSendBufferSize(256 * 1024);
                    clientSockets.add(client);
                    Log.i(TAG, "新控制器客户端已连接: " + client.getRemoteSocketAddress());

                    // 启动监听反向控制指令接收线程
                    new Thread(() -> handleIncomingControl(client), "FastMirrorClientHandler").start();
                }
            } catch (Exception e) {
                if (isRunning) {
                    Log.w(TAG, "FastMirror 服务监听异常退出: " + e.getMessage());
                }
            } finally {
                isRunning = false;
            }
        }, "FastMirrorAcceptor");
        serverThread.start();
    }

    private static boolean readFully(InputStream in, byte[] buffer, int len) throws Exception {
        int total = 0;
        while (total < len) {
            int n = in.read(buffer, total, len - total);
            if (n < 0) return false;
            total += n;
        }
        return true;
    }

    private void handleIncomingControl(Socket client) {
        try {
            InputStream in = client.getInputStream();
            byte[] headerBuf = new byte[16];

            while (isRunning && !client.isClosed()) {
                if (!readFully(in, headerBuf, 16)) break;

                ByteBuffer bb = ByteBuffer.wrap(headerBuf).order(ByteOrder.BIG_ENDIAN);
                short magic = bb.getShort();
                if (magic != MAGIC) continue;

                byte msgType = bb.get();
                byte flags = bb.get();
                int payloadLen = bb.getInt();
                long timestamp = bb.getLong();

                byte[] payload = new byte[payloadLen];
                if (payloadLen > 0) {
                    if (!readFully(in, payload, payloadLen)) break;
                }

                // 处理反向控制触控与按键指令
                ByteBuffer pb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN);
                if (msgType == MSG_TOUCH_DOWN || msgType == MSG_TOUCH_MOVE || msgType == MSG_TOUCH_UP) {
                    if (payloadLen >= 5) {
                        byte pointerId = pb.get();
                        short x = pb.getShort();
                        short y = pb.getShort();
                        // 委托无障碍服务执行手势模拟
                        ControlAccessibilityService.injectTouch(msgType, x & 0xFFFF, y & 0xFFFF);
                    }
                } else if (msgType == MSG_KEY_DOWN) {
                    if (payloadLen >= 2) {
                        short keyCode = pb.getShort();
                        ControlAccessibilityService.injectKey(keyCode);
                    }
                } else if (msgType == MSG_TEXT_INPUT) {
                    if (payloadLen > 0) {
                        String text = new String(payload, "UTF-8");
                        ControlAccessibilityService.injectText(text);
                    }
                }
            }
        } catch (Exception e) {
            Log.i(TAG, "控制器客户端断开: " + e.getMessage());
        } finally {
            clientSockets.remove(client);
            try {
                client.close();
            } catch (Exception ignored) {}
        }
    }

    public synchronized void setSpsPps(byte[] spsPps) {
        if (spsPps != null && spsPps.length > 0) {
            this.cachedSpsPps = spsPps.clone();
            Log.i(TAG, "FastMirror 已缓存 SPS/PPS 配置信息 (" + spsPps.length + " bytes)");
        }
    }

    private static boolean containsSps(byte[] data) {
        if (data == null || data.length < 5) return false;
        for (int i = 0; i < data.length - 4; i++) {
            if (data[i] == 0 && data[i + 1] == 0 && ((data[i + 2] == 1 && (data[i + 3] & 0x1F) == 7) ||
                    (data[i + 2] == 0 && data[i + 3] == 1 && (data[i + 4] & 0x1F) == 7))) {
                return true;
            }
        }
        return false;
    }

    public void sendVideo(byte[] naluData, boolean isKeyFrame, long ptsUs) {
        if (clientSockets.isEmpty() || naluData == null || naluData.length == 0) return;

        byte[] payloadToSend = naluData;
        if (isKeyFrame && cachedSpsPps != null && !containsSps(naluData)) {
            byte[] combined = new byte[cachedSpsPps.length + naluData.length];
            System.arraycopy(cachedSpsPps, 0, combined, 0, cachedSpsPps.length);
            System.arraycopy(naluData, 0, combined, cachedSpsPps.length, naluData.length);
            payloadToSend = combined;
        }

        byte[] packet = packPacket(MSG_VIDEO_FRAME, payloadToSend);
        broadcast(packet);
    }

    public void sendAudio(byte[] audioData, int size) {
        if (clientSockets.isEmpty()) return;
        byte[] exactData = new byte[size];
        System.arraycopy(audioData, 0, exactData, 0, size);
        byte[] packet = packPacket(MSG_AUDIO_FRAME, exactData);
        broadcast(packet);
    }

    private byte[] packPacket(byte msgType, byte[] payload) {
        int totalLen = 16 + (payload != null ? payload.length : 0);
        ByteBuffer bb = ByteBuffer.allocate(totalLen).order(ByteOrder.BIG_ENDIAN);
        bb.putShort(MAGIC);
        bb.put(msgType);
        bb.put((byte) 0);
        bb.putInt(payload != null ? payload.length : 0);
        bb.putLong(System.currentTimeMillis() * 1000L);
        if (payload != null) {
            bb.put(payload);
        }
        return bb.array();
    }

    private void broadcast(byte[] packet) {
        for (Socket s : clientSockets) {
            try {
                OutputStream out = s.getOutputStream();
                out.write(packet);
                out.flush();
            } catch (Exception e) {
                clientSockets.remove(s);
                try {
                    s.close();
                } catch (Exception ignored) {}
            }
        }
    }

    public void stopServer() {
        isRunning = false;
        try {
            if (serverSocket != null) serverSocket.close();
        } catch (Exception ignored) {}
        for (Socket s : clientSockets) {
            try {
                s.close();
            } catch (Exception ignored) {}
        }
        clientSockets.clear();
    }
}

