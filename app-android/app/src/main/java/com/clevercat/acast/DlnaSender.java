package com.clevercat.acast;

import android.content.Context;
import android.util.Log;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class DlnaSender {

    private static final String TAG = "DlnaSender";

    public interface OnDeviceFoundListener {
        void onFound(String name, String controlUrl);
    }

    public static void discoverDevices(Context context, OnDeviceFoundListener listener) {
        new Thread(() -> {
            try {
                DatagramSocket socket = new DatagramSocket();
                socket.setSoTimeout(3000);

                String msearch =
                        "M-SEARCH * HTTP/1.1\r\n" +
                        "HOST: 239.255.255.250:1900\r\n" +
                        "MAN: \"ssdp:discover\"\r\n" +
                        "MX: 3\r\n" +
                        "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";

                byte[] sendData = msearch.getBytes();
                DatagramPacket sendPacket = new DatagramPacket(
                        sendData, sendData.length,
                        InetAddress.getByName("239.255.255.250"), 1900
                );
                socket.send(sendPacket);

                byte[] buf = new byte[2048];
                long start = System.currentTimeMillis();
                while (System.currentTimeMillis() - start < 3500) {
                    try {
                        DatagramPacket receivePacket = new DatagramPacket(buf, buf.length);
                        socket.receive(receivePacket);
                        String response = new String(receivePacket.getData(), 0, receivePacket.getLength());

                        Pattern locPattern = Pattern.compile("(?i)LOCATION:\\s*([^\\r\\n]+)");
                        Matcher m = locPattern.matcher(response);
                        if (m.find()) {
                            String location = m.group(1).trim();
                            parseDeviceDescription(location, listener);
                        }
                    } catch (Exception ignored) {}
                }
                socket.close();
            } catch (Exception e) {
                Log.w(TAG, "SSDP 扫描失败: " + e.getMessage());
            }
        }).start();
    }

    private static void parseDeviceDescription(String locationUrl, OnDeviceFoundListener listener) {
        new Thread(() -> {
            try {
                URL url = new URL(locationUrl);
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setConnectTimeout(3000);
                conn.setReadTimeout(3000);

                BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line);
                }
                reader.close();

                String xml = sb.toString();
                String name = "智能电视 (" + url.getHost() + ")";
                Pattern namePattern = Pattern.compile("<friendlyName>([^<]+)</friendlyName>");
                Matcher nm = namePattern.matcher(xml);
                if (nm.find()) {
                    name = nm.group(1);
                }

                String controlUrl = "http://" + url.getHost() + ":" + url.getPort() + "/AVTransport/control";
                Pattern ctrlPattern = Pattern.compile("<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>\\s*<serviceId>[^<]+</serviceId>\\s*<controlURL>([^<]+)</controlURL>");
                Matcher cm = ctrlPattern.matcher(xml);
                if (cm.find()) {
                    String rel = cm.group(1);
                    if (!rel.startsWith("/")) rel = "/" + rel;
                    controlUrl = "http://" + url.getHost() + ":" + url.getPort() + rel;
                }

                if (listener != null) {
                    listener.onFound(name, controlUrl);
                }
            } catch (Exception ignored) {}
        }).start();
    }

    public static void playMediaOnTv(String controlUrl, String mediaUrl) {
        new Thread(() -> {
            try {
                // 1. SetAVTransportURI
                String soapBody =
                        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\n" +
                        "  <s:Body>\n" +
                        "    <u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\n" +
                        "      <InstanceID>0</InstanceID>\n" +
                        "      <CurrentURI>" + mediaUrl + "</CurrentURI>\n" +
                        "      <CurrentURIMetaData></CurrentURIMetaData>\n" +
                        "    </u:SetAVTransportURI>\n" +
                        "  </s:Body>\n" +
                        "</s:Envelope>";

                sendSoap(controlUrl, "SetAVTransportURI", soapBody);

                // 2. Play
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
            } catch (Exception e) {
                Log.e(TAG, "DLNA 投屏播放失败: " + e.getMessage());
            }
        }).start();
    }

    private static void sendSoap(String controlUrl, String action, String body) throws Exception {
        URL url = new URL(controlUrl);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
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
