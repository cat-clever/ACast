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

    private static final FastMirrorSender INSTANCE = new FastMirrorSender();

    public static FastMirrorSender getInstance() {
        return INSTANCE;
    }

    private ServerSocket serverSocket;
    private boolean isRunning = false;
    private Thread serverThread;
    private final CopyOnWriteArrayList<Socket> clientSockets = new CopyOnWriteArrayList<>();

    public void startServer(int port) {
        if (isRunning) return;
        isRunning = true;

        serverThread = new Thread(() -> {
            try {
                serverSocket = new ServerSocket(port);
                Log.i(TAG, "FastMirror 投屏与反控服务已监听端口: " + port);

                while (isRunning) {
                    Socket client = serverSocket.accept();
                    client.setTcpNoDelay(true);
                    clientSockets.add(client);
                    Log.i(TAG, "新控制器客户端已连接: " + client.getRemoteSocketAddress());

                    // 启动监听反向控制指令接收线程
                    new Thread(() -> handleIncomingControl(client)).start();
                }
            } catch (Exception e) {
                Log.w(TAG, "FastMirror 服务停止: " + e.getMessage());
            }
        });
        serverThread.start();
    }

    private void handleIncomingControl(Socket client) {
        try {
            InputStream in = client.getInputStream();
            byte[] headerBuf = new byte[16];

            while (isRunning && !client.isClosed()) {
                int read = in.read(headerBuf);
                if (read < 16) break;

                ByteBuffer bb = ByteBuffer.wrap(headerBuf).order(ByteOrder.BIG_ENDIAN);
                short magic = bb.getShort();
                if (magic != MAGIC) continue;

                byte msgType = bb.get();
                byte flags = bb.get();
                int payloadLen = bb.getInt();
                long timestamp = bb.getLong();

                byte[] payload = new byte[payloadLen];
                if (payloadLen > 0) {
                    int n = in.read(payload);
                    if (n < payloadLen) break;
                }

                // 处理反向控制触控与按键指令
                ByteBuffer pb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN);
                if (msgType == MSG_TOUCH_DOWN || msgType == MSG_TOUCH_MOVE || msgType == MSG_TOUCH_UP) {
                    if (payloadLen >= 7) {
                        byte pointerId = pb.get();
                        short x = pb.getShort();
                        short y = pb.getShort();
                        // 委托无障碍服务执行手势模拟
                        ControlAccessibilityService.injectTouch(msgType, x, y);
                    }
                } else if (msgType == MSG_KEY_DOWN) {
                    if (payloadLen >= 3) {
                        short keyCode = pb.getShort();
                        ControlAccessibilityService.injectKey(keyCode);
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

    public void sendVideo(byte[] naluData, boolean isKeyFrame, long ptsUs) {
        if (clientSockets.isEmpty()) return;
        byte[] packet = packPacket(MSG_VIDEO_FRAME, naluData);
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

