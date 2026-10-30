package com.clevercat.acast;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.projection.MediaProjectionManager;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;

public class MainActivity extends AppCompatActivity {

    private static final String TAG = "MainActivity";
    private static final int REQUEST_MEDIA_PROJECTION = 1001;
    private static final int REQUEST_PERMISSIONS_CODE = 2002;

    private Button btnToggleCapture;
    private Button btnScanDevices;
    private Button btnCheckUpdate;
    private TextView tvStatus;
    private TextView tvDeviceHeader;
    private ListView lvDevices;

    private boolean isCapturing = false;
    private String pendingTargetDevice = null;
    private ArrayAdapter<String> deviceAdapter;
    private final ArrayList<String> deviceList = new ArrayList<>();
    private final List<PeerDiscoveryManager.DiscoveredDesktop> discoveredDesktops = new ArrayList<>();
    private final List<String> discoveredTvDevices = new ArrayList<>();
    private WifiManager.MulticastLock multicastLock;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // 注册全局异常崩溃捕获器，杜绝闪退退出
        Thread.setDefaultUncaughtExceptionHandler((thread, throwable) -> {
            Log.e(TAG, "全局捕获未处理异常: " + throwable.getMessage(), throwable);
            new Handler(Looper.getMainLooper()).post(() -> {
                Toast.makeText(getApplicationContext(), "运行时异常保护: " + throwable.getMessage(), Toast.LENGTH_LONG).show();
            });
        });

        setContentView(R.layout.activity_main);

        btnToggleCapture = findViewById(R.id.btn_toggle_capture);
        btnScanDevices = findViewById(R.id.btn_scan_tv);
        btnCheckUpdate = findViewById(R.id.btn_check_update);
        tvStatus = findViewById(R.id.tv_status);
        tvDeviceHeader = findViewById(R.id.tv_device_header);
        lvDevices = findViewById(R.id.lv_devices);

        deviceAdapter = new ArrayAdapter<>(this, android.R.layout.simple_list_item_1, deviceList);
        lvDevices.setAdapter(deviceAdapter);

        // 初始化界面状态
        updateStatusUi();

        // 预先启动本地推流与反控通信端口，随时响应局域网大屏和电脑连接
        try {
            LocalHttpTsServer.getInstance().startServer(8088);
            FastMirrorSender.getInstance().startServer(19999);
        } catch (Throwable t) {
            Log.w(TAG, "预启动本地推流端口异常: " + t.getMessage());
        }

        // 启动局域网对等发现服务，自动侦听电脑控制端
        acquireMulticastLock();
        PeerDiscoveryManager.getInstance().start(this, desktops -> runOnUiThread(() -> {
            discoveredDesktops.clear();
            discoveredDesktops.addAll(desktops);
            refreshDeviceListUi();
        }));

        // 在线直接自动更新
        btnCheckUpdate.setOnClickListener(v -> performUpdateCheck(true));
        performUpdateCheck(false);

        btnToggleCapture.setOnClickListener(v -> {
            if (!isCapturing) {
                requestRequiredPermissionsAndStartCapture();
            } else {
                stopScreenCapture();
            }
        });

        btnScanDevices.setOnClickListener(v -> {
            discoveredDesktops.clear();
            discoveredTvDevices.clear();
            refreshDeviceListUi();
            Toast.makeText(this, "正在全网深度扫描局域网电脑与大屏设备...", Toast.LENGTH_SHORT).show();

            acquireMulticastLock();

            // 1. 扫描电脑控制端
            PeerDiscoveryManager.getInstance().searchDesktops();

            // 2. 扫描 DLNA 电视大屏
            DlnaSender.discoverDevices(this, (name, controlUrl) -> runOnUiThread(() -> {
                String item = name + " -> " + controlUrl;
                if (!discoveredTvDevices.contains(item)) {
                    discoveredTvDevices.add(item);
                    refreshDeviceListUi();
                }
            }));

            // 4 秒后若仍未搜到任何设备，给用户贴心指引
            new Handler(Looper.getMainLooper()).postDelayed(() -> {
                if (deviceList.isEmpty()) {
                    Toast.makeText(MainActivity.this, "未搜到设备。请确认手机与电脑/电视连接在同一 Wi-Fi，且电脑控制端已打开或电视已开机", Toast.LENGTH_LONG).show();
                }
            }, 4000);
        });

        // 点击设备项：先判断是电脑控制端还是大屏电视
        lvDevices.setOnItemClickListener((parent, view, position, id) -> {
            if (position < 0 || position >= deviceList.size()) return;
            String selected = deviceList.get(position);

            if (!isCapturing) {
                pendingTargetDevice = selected;
                Toast.makeText(this, "⚠️ 请先开启屏幕投屏！正在为您调起授权...", Toast.LENGTH_SHORT).show();
                requestRequiredPermissionsAndStartCapture();
                return;
            }
            handleDeviceClick(selected);
        });
    }

    private synchronized void refreshDeviceListUi() {
        deviceList.clear();

        // 1. 电脑控制端列表 (💻)
        for (PeerDiscoveryManager.DiscoveredDesktop d : discoveredDesktops) {
            deviceList.add("💻 " + d.name + " (" + d.ip + ")");
        }

        // 2. 大屏电视列表 (📺)
        for (String tv : discoveredTvDevices) {
            deviceList.add("📺 " + tv);
        }

        deviceAdapter.notifyDataSetChanged();
    }

    private void handleDeviceClick(String selected) {
        if (selected == null) return;

        if (selected.startsWith("💻 ")) {
            // 点击了电脑控制端：提取 IP 并发送直连请求
            String info = selected.substring(3).trim();
            int lParen = info.lastIndexOf('(');
            int rParen = info.lastIndexOf(')');
            if (lParen != -1 && rParen != -1 && rParen > lParen) {
                String desktopName = info.substring(0, lParen).trim();
                String desktopIp = info.substring(lParen + 1, rParen).trim();

                PeerDiscoveryManager.getInstance().sendConnectRequestToDesktop(desktopIp);
                Toast.makeText(this, "🎉 已向电脑【" + desktopName + "】发起连接，控制通道已建立！", Toast.LENGTH_SHORT).show();
                tvStatus.setText("✓ 已连接电脑【" + desktopName + "】(屏幕音画传输与反控就绪)");
                tvStatus.setTextColor(0xFF2E7D32);
            }
        } else if (selected.startsWith("📺 ")) {
            // 点击了大屏电视：提取设备参数并发起 DLNA 投屏
            String tvItem = selected.substring(3).trim();
            castToDevice(tvItem);
        }
    }

    private void acquireMulticastLock() {
        try {
            if (multicastLock == null) {
                WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
                if (wifi != null) {
                    multicastLock = wifi.createMulticastLock("ACastMulticastLock");
                    multicastLock.setReferenceCounted(true);
                }
            }
            if (multicastLock != null && !multicastLock.isHeld()) {
                multicastLock.acquire();
            }
        } catch (Throwable t) {
            Log.w(TAG, "获取 MulticastLock 异常: " + t.getMessage());
        }
    }

    public static String getLocalIpAddress(Context context) {
        try {
            if (context != null) {
                WifiManager wm = (WifiManager) context.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
                if (wm != null && wm.getConnectionInfo() != null) {
                    int ip = wm.getConnectionInfo().getIpAddress();
                    if (ip != 0) {
                        return (ip & 0xFF) + "." + ((ip >> 8) & 0xFF) + "." + ((ip >> 16) & 0xFF) + "." + ((ip >> 24) & 0xFF);
                    }
                }
            }
            Enumeration<NetworkInterface> en = NetworkInterface.getNetworkInterfaces();
            while (en.hasMoreElements()) {
                NetworkInterface intf = en.nextElement();
                Enumeration<InetAddress> enumIpAddr = intf.getInetAddresses();
                while (enumIpAddr.hasMoreElements()) {
                    InetAddress inetAddress = enumIpAddr.nextElement();
                    if (!inetAddress.isLoopbackAddress() && inetAddress instanceof Inet4Address) {
                        return inetAddress.getHostAddress();
                    }
                }
            }
        } catch (Throwable ignored) {}
        return "127.0.0.1";
    }

    private void requestRequiredPermissionsAndStartCapture() {
        List<String> neededPermissions = new ArrayList<>();
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            neededPermissions.add(Manifest.permission.RECORD_AUDIO);
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                neededPermissions.add(Manifest.permission.POST_NOTIFICATIONS);
            }
        }

        if (!neededPermissions.isEmpty()) {
            ActivityCompat.requestPermissions(this, neededPermissions.toArray(new String[0]), REQUEST_PERMISSIONS_CODE);
        } else {
            launchMediaProjectionPrompt();
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_PERMISSIONS_CODE) {
            launchMediaProjectionPrompt();
        }
    }

    private void launchMediaProjectionPrompt() {
        try {
            MediaProjectionManager manager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            if (manager != null) {
                startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_MEDIA_PROJECTION);
            } else {
                Toast.makeText(this, "设备不支持屏幕录制", Toast.LENGTH_SHORT).show();
            }
        } catch (Throwable t) {
            Log.e(TAG, "调起录屏弹窗异常: " + t.getMessage(), t);
            Toast.makeText(this, "调起录屏失败: " + t.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_MEDIA_PROJECTION) {
            if (resultCode == RESULT_OK && data != null) {
                startCaptureService(resultCode, data);
            } else {
                Toast.makeText(this, "未授予屏幕录制权限，无法开启投屏", Toast.LENGTH_SHORT).show();
                pendingTargetDevice = null;
            }
        }
    }

    private void startCaptureService(int resultCode, Intent data) {
        try {
            Intent serviceIntent = new Intent(this, ScreenCaptureService.class);
            serviceIntent.putExtra("code", resultCode);
            serviceIntent.putExtra("resultCode", resultCode);
            serviceIntent.putExtra("data", data);

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent);
            } else {
                startService(serviceIntent);
            }

            isCapturing = true;
            btnToggleCapture.setText(R.string.btn_stop_capture);
            updateStatusUi();

            // 通知对等发现模块投屏已激活，立即广播
            PeerDiscoveryManager.getInstance().setCapturing(true);

            // 若之前点击了某台设备，待服务启动后自动完成连接
            if (pendingTargetDevice != null) {
                String target = pendingTargetDevice;
                pendingTargetDevice = null;
                new Handler(Looper.getMainLooper()).postDelayed(() -> handleDeviceClick(target), 600);
            }
        } catch (Throwable t) {
            Log.e(TAG, "启动投屏服务失败: " + t.getMessage(), t);
            Toast.makeText(this, "启动服务异常: " + t.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void stopScreenCapture() {
        try {
            Intent serviceIntent = new Intent(this, ScreenCaptureService.class);
            stopService(serviceIntent);
        } catch (Throwable ignored) {}

        isCapturing = false;
        pendingTargetDevice = null;
        btnToggleCapture.setText(R.string.btn_start_capture);
        PeerDiscoveryManager.getInstance().setCapturing(false);
        updateStatusUi();
    }

    private void castToDevice(String deviceItem) {
        if (deviceItem == null) return;
        String controlUrl = deviceItem;
        String deviceName = deviceItem;
        int arrowIdx = deviceItem.lastIndexOf(" -> ");
        if (arrowIdx != -1) {
            deviceName = deviceItem.substring(0, arrowIdx).trim();
            controlUrl = deviceItem.substring(arrowIdx + 4).trim();
        }
        String myIp = getLocalIpAddress(this);
        String streamUrl = "http://" + myIp + ":8088/live.m3u8";
        DlnaSender.playMediaOnTv(deviceName, controlUrl, streamUrl);
        Toast.makeText(this, "已发起投屏至【" + deviceName + "】！", Toast.LENGTH_SHORT).show();
        tvStatus.setText("✓ 正在向【" + deviceName + "】投屏中 (实时音画传输中)");
    }

    private void updateStatusUi() {
        String ip = getLocalIpAddress(this);
        if (isCapturing) {
            tvStatus.setText("✓ 投屏进行中 (本机IP: " + ip + ")\n📡 HLS 直播流: http://" + ip + ":8088/live.m3u8\n请选择下方控制端电脑直连，或点击大屏设备投屏");
            tvStatus.setTextColor(0xFF2E7D32); // 绿色
            if (tvDeviceHeader != null) {
                tvDeviceHeader.setText("3. 选择目标设备 (💻 电脑控制端 / 📺 大屏电视):");
            }
        } else {
            tvStatus.setText("● 本地推流服务已就绪 (端口 8088 / 19999)\n📡 HLS 地址: http://" + ip + ":8088/live.m3u8\n请点击【开启投屏】开始实时传输屏幕");
            tvStatus.setTextColor(0xFFE65100); // 醒目橙色
            if (tvDeviceHeader != null) {
                tvDeviceHeader.setText("3. 选择目标设备 (⚠️ 请先完成第1步开启投屏):");
            }
        }
    }

    private void performUpdateCheck(boolean userTriggered) {
        if (userTriggered) {
            Toast.makeText(this, "正在检查最新版本...", Toast.LENGTH_SHORT).show();
        }
        AutoUpdater.checkUpdate(this, new AutoUpdater.UpdateCallback() {
            @Override
            public void onCheckResult(boolean hasUpdate, String latestVersion, String downloadUrl) {
                runOnUiThread(() -> {
                    if (hasUpdate) {
                        Toast.makeText(MainActivity.this, "发现新版本 " + latestVersion + "，正在后台直接下载更新...", Toast.LENGTH_LONG).show();
                        AutoUpdater.downloadAndInstall(MainActivity.this, downloadUrl, new AutoUpdater.UpdateCallback() {
                            @Override
                            public void onCheckResult(boolean h, String v, String d) {}

                            @Override
                            public void onDownloadProgress(int progress, String message) {
                                runOnUiThread(() -> tvStatus.setText("【更新中】" + message));
                            }

                            @Override
                            public void onError(String error) {
                                runOnUiThread(() -> Toast.makeText(MainActivity.this, error, Toast.LENGTH_SHORT).show());
                            }
                        });
                    } else if (userTriggered) {
                        Toast.makeText(MainActivity.this, "当前已是最新版本！", Toast.LENGTH_SHORT).show();
                    }
                });
            }

            @Override
            public void onDownloadProgress(int progress, String message) {}

            @Override
            public void onError(String error) {
                if (userTriggered) {
                    runOnUiThread(() -> Toast.makeText(MainActivity.this, error, Toast.LENGTH_SHORT).show());
                }
            }
        });
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        PeerDiscoveryManager.getInstance().stop();
        if (multicastLock != null && multicastLock.isHeld()) {
            multicastLock.release();
        }
    }
}
