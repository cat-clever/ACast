package com.clevercat.acast;

import android.util.Log;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.CopyOnWriteArrayList;

public class LocalHttpTsServer {

    private static final String TAG = "LocalHttpTsServer";
    private static final LocalHttpTsServer INSTANCE = new LocalHttpTsServer();

    public static LocalHttpTsServer getInstance() {
        return INSTANCE;
    }

    private ServerSocket serverSocket;
    private boolean isRunning = false;
    private final CopyOnWriteArrayList<Socket> clientSockets = new CopyOnWriteArrayList<>();

    public void startServer(int port) {
        if (isRunning) return;
        isRunning = true;

        new Thread(() -> {
            try {
                serverSocket = new ServerSocket(port);
                Log.i(TAG, "本地 HTTP-TS 实时流服务已监听端口: " + port);

                while (isRunning) {
                    Socket client = serverSocket.accept();
                    clientSockets.add(client);

                    new Thread(() -> handleHttpClient(client)).start();
                }
            } catch (Exception e) {
                Log.w(TAG, "HTTP-TS 服务已停止: " + e.getMessage());
            }
        }).start();
    }

    private void handleHttpClient(Socket client) {
        try {
            InputStream in = client.getInputStream();
            byte[] buf = new byte[1024];
            int read = in.read(buf);
            if (read > 0) {
                OutputStream out = client.getOutputStream();
                String responseHeader =
                        "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: video/mp2t\r\n" +
                        "Connection: close\r\n" +
                        "Access-Control-Allow-Origin: *\r\n\r\n";
                out.write(responseHeader.getBytes("UTF-8"));
                out.flush();

                while (isRunning && !client.isClosed()) {
                    Thread.sleep(100);
                }
            }
        } catch (Exception ignored) {
        } finally {
            clientSockets.remove(client);
            try { client.close(); } catch (Exception ignored) {}
        }
    }

    public void pushVideo(byte[] data, boolean isKeyFrame, long ptsUs) {
        // 分发给电视拉流客户端
    }

    public void pushAudio(byte[] data, int size) {
        // 分发给电视拉流客户端
    }

    public void stopServer() {
        isRunning = false;
        try {
            if (serverSocket != null) serverSocket.close();
        } catch (Exception ignored) {}
        for (Socket s : clientSockets) {
            try { s.close(); } catch (Exception ignored) {}
        }
        clientSockets.clear();
    }
}
