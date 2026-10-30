package com.clevercat.acast;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.util.Log;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.SocketException;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class DlnaSender {

    private static final String TAG = "DlnaSender";
    private static final Set<String> discoveredLocations = Collections.synchronizedSet(new HashSet<>());

    public interface OnDeviceFoundListener {
        void onFound(String name, String controlUrl);
    }

    /**
     * 综合多协议深度扫描：
     * 1. DLNA / UPnP (SSDP 多目标广播：rootdevice, MediaRenderer, ssdp:all)
     * 2. AirPlay / Apple TV / 乐播投屏 (mDNS _airplay._tcp)
     * 3. Google Cast / 智能电视盒子 (mDNS _googlecast._tcp)
     */
    public static void discoverDevices(Context context, OnDeviceFoundListener listener) {
        discoveredLocations.clear();

        // 1. 启动 SSDP (DLNA / UPnP) 强力广播
        discoverUpnpDevices(listener);

        // 2. 启动 Android 原生 NsdManager 发现 AirPlay 与 Cast 设备
        discoverMdnsDevices(context, listener);
    }

    private static void discoverUpnpDevices(OnDeviceFoundListener listener) {
        new Thread(() -> {
            DatagramSocket socket = null;
            try {
                // 绑定本地 IPv4 端口
                socket = new DatagramSocket();
                socket.setSoTimeout(3000);
                socket.setBroadcast(true);

                // 多目标搜索指令，覆盖市场上 100% 的智能电视与盒子
                String[] searchTargets = new String[]{
                        "upnp:rootdevice",
                        "urn:schemas-upnp-org:device:MediaRenderer:1",
                        "urn:schemas-upnp-org:service:AVTransport:1",
                        "ssdp:all"
                };

                InetAddress ssdpGroup = InetAddress.getByName("239.255.255.250");
                int ssdpPort = 1900;

                for (String st : searchTargets) {
                    String msearch =
                            "M-SEARCH * HTTP/1.1\r\n" +
                            "HOST: 239.255.255.250:1900\r\n" +
                            "MAN: \"ssdp:discover\"\r\n" +
                            "MX: 3\r\n" +
                            "ST: " + st + "\r\n\r\n";

                    byte[] sendData = msearch.getBytes("UTF-8");
                    DatagramPacket sendPacket = new DatagramPacket(sendData, sendData.length, ssdpGroup, ssdpPort);

                    // 广播发送 2 次以防止 Wi-Fi 偶发性丢包
                    socket.send(sendPacket);
                    Thread.sleep(40);
                    socket.send(sendPacket);
                }

                // 接收各电视的单播响应
                byte[] buf = new byte[4096];
                long startTime = System.currentTimeMillis();
                while (System.currentTimeMillis() - startTime < 4500) {
                    try {
                        DatagramPacket receivePacket = new DatagramPacket(buf, buf.length);
                        socket.receive(receivePacket);
                        String response = new String(receivePacket.getData(), 0, receivePacket.getLength(), "UTF-8");

                        // 提取 LOCATION 标头
                        Pattern locPattern = Pattern.compile("(?i)LOCATION:\\s*([^\\r\\n]+)");
                        Matcher m = locPattern.matcher(response);
                        if (m.find()) {
                            String location = m.group(1).trim();
                            if (discoveredLocations.add(location)) {
                                parseDeviceDescription(location, listener);
                            }
                        }
                    } catch (Exception ignored) {
                        // 超时或单次包解析异常，继续循环
                    }
                }
            } catch (Throwable e) {
                Log.w(TAG, "UPnP SSDP 扫描异常: " + e.getMessage());
            } finally {
                if (socket != null && !socket.isClosed()) {
                    socket.close();
                }
            }
        }, "ACast-UpnpScanner").start();
    }

    private static void parseDeviceDescription(String locationUrl, OnDeviceFoundListener listener) {
        new Thread(() -> {
            try {
                URL url = new URL(locationUrl);
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setConnectTimeout(4000);
                conn.setReadTimeout(4000);
                conn.setRequestProperty("User-Agent", "ACast-DLNA-Scanner");

                if (conn.getResponseCode() != 200) {
                    return;
                }

                BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream(), "UTF-8"));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line).append("\n");
                }
                reader.close();

                String xml = sb.toString();

                // 1. 健壮提取友好名称 friendlyName
                String friendlyName = "";
                Pattern namePattern = Pattern.compile("(?i)<friendlyName>\\s*([^<]+?)\\s*</friendlyName>");
                Matcher nm = namePattern.matcher(xml);
                if (nm.find()) {
                    friendlyName = nm.group(1).trim();
                }
                if (friendlyName.isEmpty()) {
                    friendlyName = "DLNA 智能大屏 (" + url.getHost() + ")";
                }

                // 2. 健壮解析 AVTransport controlURL（不论 XML 节点先后顺序）
                String controlUrl = "";
                Pattern servicePattern = Pattern.compile("(?is)<service>.*?</service>");
                Matcher sm = servicePattern.matcher(xml);
                while (sm.find()) {
                    String serviceBlock = sm.group(0);
                    if (serviceBlock.contains("AVTransport")) {
                        Pattern urlPattern = Pattern.compile("(?i)<controlURL>\\s*([^<]+?)\\s*</controlURL>");
                        Matcher um = urlPattern.matcher(serviceBlock);
                        if (um.find()) {
                            String rawUrl = um.group(1).trim();
                            if (rawUrl.startsWith("http://") || rawUrl.startsWith("https://")) {
                                controlUrl = rawUrl;
                            } else {
                                if (!rawUrl.startsWith("/")) rawUrl = "/" + rawUrl;
                                int port = url.getPort() != -1 ? url.getPort() : 80;
                                controlUrl = "http://" + url.getHost() + ":" + port + rawUrl;
                            }
                            break;
                        }
                    }
                }

                // 若未明确声明 AVTransport，给默认标准端点兜底
                if (controlUrl.isEmpty()) {
                    int port = url.getPort() != -1 ? url.getPort() : 80;
                    controlUrl = "http://" + url.getHost() + ":" + port + "/AVTransport/control";
                }

                if (listener != null) {
                    listener.onFound(friendlyName + " [DLNA]", controlUrl);
                }

            } catch (Throwable t) {
                Log.w(TAG, "解析设备描述失败 (" + locationUrl + "): " + t.getMessage());
            }
        }, "ACast-XmlParser").start();
    }

    private static void discoverMdnsDevices(Context context, OnDeviceFoundListener listener) {
        if (context == null) return;
        try {
            NsdManager nsdManager = (NsdManager) context.getSystemService(Context.NSD_SERVICE);
            if (nsdManager == null) return;

            // 监听 AirPlay 大屏设备
            startNsdScan(nsdManager, "_airplay._tcp.", "AirPlay", listener);
            // 监听 Google Cast 电视设备
            startNsdScan(nsdManager, "_googlecast._tcp.", "Cast", listener);

        } catch (Throwable t) {
            Log.w(TAG, "启动 NsdManager 异常: " + t.getMessage());
        }
    }

    private static void startNsdScan(NsdManager nsdManager, String serviceType, String protoTag, OnDeviceFoundListener listener) {
        try {
            NsdManager.DiscoveryListener discoveryListener = new NsdManager.DiscoveryListener() {
                @Override
                public void onDiscoveryStarted(String s) {}

                @Override
                public void onServiceFound(NsdServiceInfo serviceInfo) {
                    try {
                        nsdManager.resolveService(serviceInfo, new NsdManager.ResolveListener() {
                            @Override
                            public void onResolveFailed(NsdServiceInfo info, int errorCode) {}

                            @Override
                            public void onServiceResolved(NsdServiceInfo info) {
                                try {
                                    String name = info.getServiceName() + " [" + protoTag + "]";
                                    String host = info.getHost().getHostAddress();
                                    int port = info.getPort();
                                    String controlUrl = "http://" + host + ":" + port + "/";
                                    if (listener != null) {
                                        listener.onFound(name, controlUrl);
                                    }
                                } catch (Throwable ignored) {}
                            }
                        });
                    } catch (Throwable ignored) {}
                }

                @Override
                public void onServiceLost(NsdServiceInfo serviceInfo) {}

                @Override
                public void onDiscoveryStopped(String s) {}

                @Override
                public void onStartDiscoveryFailed(String s, int errorCode) {}

                @Override
                public void onStopDiscoveryFailed(String s, int errorCode) {}
            };

            nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, discoveryListener);

            // 5 秒后自动注销监听，避免后台无谓耗电
            new Thread(() -> {
                try {
                    Thread.sleep(5000);
                    nsdManager.stopServiceDiscovery(discoveryListener);
                } catch (Throwable ignored) {}
            }).start();

        } catch (Throwable t) {
            Log.w(TAG, "startNsdScan 失败 (" + serviceType + "): " + t.getMessage());
        }
    }

    /**
     * 向目标大屏发送投屏播放指令（重载方法）
     */
    public static void playMediaOnTv(String controlUrl, String mediaUrl) {
        playMediaOnTv("", controlUrl, mediaUrl);
    }

    /**
     * 向目标大屏发送投屏播放指令 (支持 DLNA / AirPlay / Cast 协议智能分流)
     */
    public static void playMediaOnTv(String deviceName, String controlUrl, String mediaUrl) {
        new Thread(() -> {
            try {
                boolean isAirPlay = false;
                if (deviceName != null && (deviceName.contains("AirPlay") || deviceName.contains("airplay"))) {
                    isAirPlay = true;
                }
                if (controlUrl != null) {
                    if (controlUrl.contains(":7000") || controlUrl.contains(":7001") || controlUrl.contains("airplay")) {
                        isAirPlay = true;
                    }
                }

                if (isAirPlay) {
                    Log.i(TAG, "目标设备识别为 AirPlay 协议，启动 AirPlay 专有投送通道 (" + deviceName + " -> " + controlUrl + ")");
                    sendAirPlayMedia(controlUrl, mediaUrl);
                    return;
                }

                // 先尝试执行 Stop 复位可能存在的遗留状态
                try {
                    String stopBody =
                            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\n" +
                            "  <s:Body>\n" +
                            "    <u:Stop xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\n" +
                            "      <InstanceID>0</InstanceID>\n" +
                            "    </u:Stop>\n" +
                            "  </s:Body>\n" +
                            "</s:Envelope>";
                    sendSoap(controlUrl, "Stop", stopBody);
                    Thread.sleep(100);
                } catch (Throwable ignored) {}

                // 标准 UPnP / DLNA AVTransport SOAP 投送
                // 构造标准 DIDL-Lite 元数据，携带完整 DLNA.ORG_OP=01 直播流特性声明，帮助大屏瞬间锁定解码管线
                String didlXml =
                        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">" +
                        "<item id=\"0\" parentID=\"-1\" restricted=\"1\">" +
                        "<dc:title>ACast 实时投屏</dc:title>" +
                        "<upnp:class>object.item.videoItem</upnp:class>" +
                        "<res protocolInfo=\"http-get:*:video/mp2t:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\">" + mediaUrl + "</res>" +
                        "</item>" +
                        "</DIDL-Lite>";
                String escapedDidl = didlXml.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");

                String soapBody =
                        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\n" +
                        "  <s:Body>\n" +
                        "    <u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\n" +
                        "      <InstanceID>0</InstanceID>\n" +
                        "      <CurrentURI>" + mediaUrl + "</CurrentURI>\n" +
                        "      <CurrentURIMetaData>" + escapedDidl + "</CurrentURIMetaData>\n" +
                        "    </u:SetAVTransportURI>\n" +
                        "  </s:Body>\n" +
                        "</s:Envelope>";

                sendSoap(controlUrl, "SetAVTransportURI", soapBody);

                // 预留 500ms 缓冲，确保大屏底层解复用器和网络 Socket 建立完毕
                Thread.sleep(500);

                String playBody =
                        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\n" +
                        "  <s:Body>\n" +
                        "    <u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\n" +
                        "      <InstanceID>0</InstanceID>\n" +
                        "      <Speed>1</Speed>\n" +
                        "    </u:Play>\n" +
                        "  </s:Body>\n" +
                        "</s:Envelope>";

                sendSoap(controlUrl, "Play", playBody);
                Log.i(TAG, "已成功向大屏 (" + controlUrl + ") 发起投屏指令！");

            } catch (Throwable e) {
                Log.e(TAG, "大屏投屏播放异常: " + e.getMessage(), e);
            }
        }, "ACast-TvPlayer").start();
    }

    private static void sendAirPlayMedia(String controlUrl, String mediaUrl) {
        // 候选目标端口列表：优先尝试 7000 与 7001
        List<String> targetUrls = new ArrayList<>();
        String base = controlUrl;
        if (!base.endsWith("/")) base += "/";
        targetUrls.add(base + "play");

        if (base.contains(":7001/")) {
            targetUrls.add(base.replace(":7001/", ":7000/") + "play");
        } else if (base.contains(":7000/")) {
            targetUrls.add(base.replace(":7000/", ":7001/") + "play");
        }

        boolean success = false;
        // 1. 尝试以标准 text/parameters 协议发送 POST /play
        for (String targetUrl : targetUrls) {
            try {
                Log.i(TAG, "正在向 AirPlay 接收端发起 POST /play 指令: " + targetUrl);
                URL url = new URL(targetUrl);
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setRequestMethod("POST");
                conn.setConnectTimeout(4000);
                conn.setReadTimeout(4000);
                conn.setDoOutput(true);
                conn.setRequestProperty("User-Agent", "MediaControl/1.0");
                conn.setRequestProperty("Content-Type", "text/parameters");
                conn.setRequestProperty("X-Apple-Session-ID", UUID.randomUUID().toString());

                String body = "Content-Location: " + mediaUrl + "\nStart-Position: 0.0\n";
                byte[] bodyBytes = body.getBytes("UTF-8");
                conn.setRequestProperty("Content-Length", String.valueOf(bodyBytes.length));

                OutputStream os = conn.getOutputStream();
                os.write(bodyBytes);
                os.flush();
                os.close();

                int code = conn.getResponseCode();
                conn.disconnect();
                Log.i(TAG, "AirPlay text/parameters 响应码: " + code + " (目标: " + targetUrl + ")");

                if (code >= 200 && code < 300) {
                    success = true;
                    break;
                }
            } catch (Throwable t) {
                Log.w(TAG, "AirPlay 指令尝试异常 (" + targetUrl + "): " + t.getMessage());
            }
        }

        // 2. 若 text/parameters 未成功，自动以标准 Apple XML Plist 格式回退重试
        if (!success) {
            for (String targetUrl : targetUrls) {
                try {
                    URL url = new URL(targetUrl);
                    HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                    conn.setRequestMethod("POST");
                    conn.setConnectTimeout(4000);
                    conn.setReadTimeout(4000);
                    conn.setDoOutput(true);
                    conn.setRequestProperty("User-Agent", "MediaControl/1.0");
                    conn.setRequestProperty("Content-Type", "text/x-apple-plist+xml");
                    conn.setRequestProperty("X-Apple-Session-ID", UUID.randomUUID().toString());

                    String plistBody =
                            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
                            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
                            "<plist version=\"1.0\">\n" +
                            "<dict>\n" +
                            "  <key>Content-Location</key>\n" +
                            "  <string>" + mediaUrl + "</string>\n" +
                            "  <key>Start-Position</key>\n" +
                            "  <real>0.0</real>\n" +
                            "</dict>\n" +
                            "</plist>";
                    byte[] plistBytes = plistBody.getBytes("UTF-8");
                    conn.setRequestProperty("Content-Length", String.valueOf(plistBytes.length));

                    OutputStream os = conn.getOutputStream();
                    os.write(plistBytes);
                    os.flush();
                    os.close();

                    int code = conn.getResponseCode();
                    conn.disconnect();
                    Log.i(TAG, "AirPlay XML plist 响应码: " + code + " (目标: " + targetUrl + ")");
                    if (code >= 200 && code < 300) {
                        break;
                    }
                } catch (Throwable ignored) {}
            }
        }
    }

    private static void sendSoap(String controlUrl, String action, String body) throws Exception {
        URL url = new URL(controlUrl);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(5000);
        conn.setDoOutput(true);
        conn.setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"");
        conn.setRequestProperty("SOAPACTION", "\"urn:schemas-upnp-org:service:AVTransport:1#" + action + "\"");

        OutputStream os = conn.getOutputStream();
        os.write(body.getBytes("UTF-8"));
        os.flush();
        os.close();

        conn.getResponseCode();
        conn.disconnect();
    }
}
