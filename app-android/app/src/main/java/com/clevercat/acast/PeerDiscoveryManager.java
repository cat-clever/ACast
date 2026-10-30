package com.clevercat.acast;

import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import org.json.JSONObject;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

public class PeerDiscoveryManager {

    private static final String TAG = "PeerDiscoveryManager";
    public static final int DISCOVERY_PORT = 19998;
    private static final PeerDiscoveryManager INSTANCE = new PeerDiscoveryManager();

    public static PeerDiscoveryManager getInstance() {
        return INSTANCE;
    }

    public static class DiscoveredDesktop {
        public final String name;
        public final String ip;
        public final String os;
        public long lastSeen;

        public DiscoveredDesktop(String name, String ip, String os, long lastSeen) {
            this.name = name;
            this.ip = ip;
            this.os = os;
            this.lastSeen = lastSeen;
        }
    }

    public interface OnDesktopsChangedListener {
        void onDesktopsChanged(List<DiscoveredDesktop> desktops);
    }

    private final List<DiscoveredDesktop> discoveredDesktops = new CopyOnWriteArrayList<>();
    private OnDesktopsChangedListener desktopsListener;
    private DatagramSocket socket;
    private volatile boolean isRunning = false;
    private Context appContext;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private volatile boolean isCapturing = false;

    public void setCapturing(boolean capturing) {
        this.isCapturing = capturing;
        if (capturing) {
            // 开启投屏时立即广播一次手机存在
            broadcastPhoneBeacon();
        }
    }

    public synchronized void start(Context context, OnDesktopsChangedListener listener) {
        if (isRunning) {
            this.desktopsListener = listener;
            return;
        }
        this.appContext = context.getApplicationContext();
        this.desktopsListener = listener;
        this.isRunning = true;

        new Thread(this::listenLoop, "DiscoveryListenThread").start();
        new Thread(this::beaconLoop, "DiscoveryBeaconThread").start();
    }

    public synchronized void stop() {
        isRunning = false;
        try {
            if (socket != null && !socket.isClosed()) {
                socket.close();
            }
        } catch (Throwable ignored) {}
        discoveredDesktops.clear();
    }

    public List<DiscoveredDesktop> getDiscoveredDesktops() {
        return new ArrayList<>(discoveredDesktops);
    }

    public void searchDesktops() {
        new Thread(() -> {
            try {
                JSONObject json = new JSONObject();
                json.put("cmd", "discover_desktop");
                sendUdpPacket(json.toString(), InetAddress.getByName("255.255.255.255"), DISCOVERY_PORT);
            } catch (Throwable t) {
                Log.w(TAG, "searchDesktops 失败: " + t.getMessage());
            }
        }).start();
    }

    public void sendConnectRequestToDesktop(String desktopIp) {
        new Thread(() -> {
            try {
                String myIp = MainActivity.getLocalIpAddress(appContext);
                String modelName = Build.BRAND + " " + Build.MODEL;

                JSONObject json = new JSONObject();
                json.put("cmd", "connect_request");
                json.put("target_ip", desktopIp);
                json.put("phone_ip", myIp);
                json.put("phone_port", 19999);
                json.put("phone_name", modelName);

                sendUdpPacket(json.toString(), InetAddress.getByName(desktopIp), DISCOVERY_PORT);
                Log.i(TAG, "已向控制端电脑 " + desktopIp + " 发送直连反控请求");
            } catch (Throwable t) {
                Log.w(TAG, "sendConnectRequestToDesktop 失败: " + t.getMessage());
            }
        }).start();
    }

    private void broadcastPhoneBeacon() {
        new Thread(() -> {
            try {
                if (appContext == null) return;
                String myIp = MainActivity.getLocalIpAddress(appContext);
                String modelName = Build.BRAND + " " + Build.MODEL;

                JSONObject json = new JSONObject();
                json.put("cmd", "phone_beacon");
                json.put("device_name", modelName);
                json.put("ip", myIp);
                json.put("port", 19999);
                json.put("model", Build.MODEL);
                json.put("status", isCapturing ? "capturing" : "ready");

                sendUdpPacket(json.toString(), InetAddress.getByName("255.255.255.255"), DISCOVERY_PORT);
            } catch (Throwable ignored) {}
        }).start();
    }

    private void sendUdpPacket(String data, InetAddress addr, int port) {
        DatagramSocket sendSock = null;
        try {
            sendSock = new DatagramSocket();
            sendSock.setBroadcast(true);
            byte[] bytes = data.getBytes("UTF-8");
            DatagramPacket packet = new DatagramPacket(bytes, bytes.length, addr, port);
            sendSock.send(packet);
        } catch (Throwable t) {
            Log.w(TAG, "sendUdpPacket 异常: " + t.getMessage());
        } finally {
            if (sendSock != null && !sendSock.isClosed()) {
                sendSock.close();
            }
        }
    }

    private void listenLoop() {
        try {
            socket = new DatagramSocket(DISCOVERY_PORT);
            socket.setReuseAddress(true);
            socket.setBroadcast(true);

            byte[] buf = new byte[2048];
            while (isRunning) {
                DatagramPacket packet = new DatagramPacket(buf, buf.length);
                socket.receive(packet);

                String msg = new String(packet.getData(), packet.getOffset(), packet.getLength(), "UTF-8");
                String remoteIp = packet.getAddress().getHostAddress();

                handleIncomingMessage(msg, remoteIp);
            }
        } catch (Throwable t) {
            if (isRunning) {
                Log.w(TAG, "listenLoop 异常退出: " + t.getMessage());
            }
        } finally {
            if (socket != null && !socket.isClosed()) {
                socket.close();
            }
        }
    }

    private void handleIncomingMessage(String msg, String remoteIp) {
        try {
            JSONObject json = new JSONObject(msg);
            String cmd = json.optString("cmd");

            if ("desktop_beacon".equals(cmd)) {
                String devName = json.optString("device_name", "Desktop-PC");
                String ip = json.optString("ip", remoteIp);
                String os = json.optString("os", "PC");
                if (ip == null || ip.isEmpty() || "127.0.0.1".equals(ip)) {
                    ip = remoteIp;
                }

                boolean changed = false;
                long now = System.currentTimeMillis();
                boolean found = false;

                for (DiscoveredDesktop d : discoveredDesktops) {
                    if (d.ip.equals(ip)) {
                        d.lastSeen = now;
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    discoveredDesktops.add(new DiscoveredDesktop(devName, ip, os, now));
                    changed = true;
                    Log.i(TAG, "🎉 自动发现局域网电脑控制端: " + devName + " (" + ip + ")");
                }

                if (changed) {
                    notifyDesktopsChanged();
                }
            } else if ("discover_phone".equals(cmd)) {
                // 电脑主动搜索手机，立即回复宣告
                broadcastPhoneBeacon();
            }
        } catch (Throwable ignored) {}
    }

    private void beaconLoop() {
        searchDesktops();

        while (isRunning) {
            try {
                Thread.sleep(2000);
            } catch (InterruptedException e) {
                break;
            }

            // 投屏中每 2 秒广播一次保活
            if (isCapturing) {
                broadcastPhoneBeacon();
            }

            // 清理超时下线的电脑
            long now = System.currentTimeMillis();
            boolean changed = false;
            Iterator<DiscoveredDesktop> it = discoveredDesktops.iterator();
            while (it.hasNext()) {
                DiscoveredDesktop d = it.next();
                if (now - d.lastSeen > 6000) {
                    discoveredDesktops.remove(d);
                    changed = true;
                }
            }
            if (changed) {
                notifyDesktopsChanged();
            }
        }
    }

    private void notifyDesktopsChanged() {
        mainHandler.post(() -> {
            if (desktopsListener != null) {
                desktopsListener.onDesktopsChanged(new ArrayList<>(discoveredDesktops));
            }
        });
    }
}

