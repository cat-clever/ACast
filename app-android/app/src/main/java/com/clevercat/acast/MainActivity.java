package com.clevercat.acast;

import android.Manifest;
import android.app.Activity;
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
import androidx.annotation.Nullable;
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
    private Button btnScanTv;
    private Button btnCheckUpdate;
    private TextView tvStatus;
    private TextView tvDeviceHeader;
    private ListView lvDevices;

    private boolean isCapturing = false;
    private String pendingTargetDevice = null;
    private ArrayAdapter<String> deviceAdapter;
    private ArrayList<String> deviceList = new ArrayList<>();
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
        btnScanTv = findViewById(R.id.btn_scan_tv);
        btnCheckUpdate = findViewById(R.id.btn_check_update);
        tvStatus = findViewById(R.id.tv_status);
        tvDeviceHeader = findViewById(R.id.tv_device_header);
        lvDevices = findViewById(R.id.lv_devices);

        deviceAdapter = new ArrayAdapter<>(this, android.R.layout.simple_list_item_1, deviceList);
        lvDevices.setAdapter(deviceAdapter);

        // 初始化界面状态
        updateStatusUi();

        // 在线直接自动更新
        btnCheckUpdate.setOnClickListener(v -> performUpdateCheck(true));
        performUpdateCheck(false);

        // 激活 Wi-Fi 组播接收锁
        acquireMulticastLock();

        btnToggleCapture.setOnClickListener(v -> {
            if (!isCapturing) {
                requestRequiredPermissionsAndStartCapture();
            } else {
                stopScreenCapture();
            }
        });

        btnScanTv.setOnClickListener(v -> {
            deviceList.clear();
            deviceAdapter.notifyDataSetChanged();
            Toast.makeText(this, "正在全网深度扫描大屏 (DLNA / Cast / AirPlay)...", Toast.LENGTH_SHORT).show();

            acquireMulticastLock();

            DlnaSender.discoverDevices(this, (name, controlUrl) -> runOnUiThread(() -> {
                String item = name + " -> " + controlUrl;
                if (!deviceList.contains(item)) {
                    deviceList.add(item);
                    deviceAdapter.notifyDataSetChanged();
                }
            }));

            // 4 秒后若仍未搜到任何设备，给用户贴心指引
            new Handler(Looper.getMainLooper()).postDelayed(() -> {
                if (deviceList.isEmpty()) {
                    Toast.makeText(MainActivity.this, "未搜到设备。请确认手机与电视连接在同一 Wi-Fi，且电视已开机并开启投屏服务", Toast.LENGTH_LONG).show();
                }
            }, 4000);
        });

        // 点击设备项：严格要求先开启投屏再点击设备
        lvDevices.setOnItemClickListener((parent, view, position, id) -> {
            String selected = deviceList.get(position);
            if (!isCapturing) {
                pendingTargetDevice = selected;
                Toast.makeText(this, "⚠️ 请先开启屏幕投屏！正在为您调起授权...", Toast.LENGTH_SHORT).show();
                requestRequiredPermissionsAndStartCapture();
                return;
            }
            castToDevice(selected);
        });
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
            WifiManager wm = (WifiManager) context.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null && wm.getConnectionInfo() != null) {
                int ip = wm.getConnectionInfo().getIpAddress();
                if (ip != 0) {
                    return (ip & 0xFF) + "." + ((ip >> 8) & 0xFF) + "." + ((ip >> 16) & 0xFF) + "." + ((ip >> 24) & 0xFF);
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
                Toast.makeText(this, "当前系统不支持录屏服务", Toast.LENGTH_SHORT).show();
            }
        } catch (Throwable t) {
            Log.e(TAG, "调起录屏授权失败: " + t.getMessage(), t);
            Toast.makeText(this, "调起录屏授权异常: " + t.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_MEDIA_PROJECTION) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                startScreenCapture(resultCode, data);
            } else {
                pendingTargetDevice = null;
                Toast.makeText(this, "用户未授予录屏权限，投屏未开启", Toast.LENGTH_SHORT).show();
                updateStatusUi();
            }
        }
    }

    private void startScreenCapture(int resultCode, Intent data) {
        try {
            Intent serviceIntent = new Intent(this, ScreenCaptureService.class);
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

            // 若之前点击了某台大屏设备，待服务启动后自动完成投屏连接
            if (pendingTargetDevice != null) {
                String target = pendingTargetDevice;
                pendingTargetDevice = null;
                // 延迟 600ms 等待本地 HTTP-TS 实时流端口启动就绪
                new Handler(Looper.getMainLooper()).postDelayed(() -> castToDevice(target), 600);
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
        String streamUrl = "http://" + myIp + ":8088/live.ts";
        DlnaSender.playMediaOnTv(controlUrl, streamUrl);
        Toast.makeText(this, "已发起投屏至【" + deviceName + "】！", Toast.LENGTH_SHORT).show();
        tvStatus.setText("✓ 正在向【" + deviceName + "】投屏中 (实时音画传输中)");
    }

    private void updateStatusUi() {
        if (isCapturing) {
            tvStatus.setText("✓ 投屏已开启：请点击下方大屏设备即可开始投屏 (支持 USB/Wi-Fi 反控)");
            tvStatus.setTextColor(0xFF2E7D32); // 绿色
            if (tvDeviceHeader != null) {
                tvDeviceHeader.setText("3. 点击大屏设备开始投屏 (✓ 投屏服务已就绪):");
            }
        } else {
            tvStatus.setText(R.string.status_ready);
            tvStatus.setTextColor(0xFFE65100); // 醒目橙色
            if (tvDeviceHeader != null) {
                tvDeviceHeader.setText("3. 点击大屏设备开始投屏 (⚠️ 请先完成第1步开启投屏):");
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
        if (multicastLock != null && multicastLock.isHeld()) {
            try {
                multicastLock.release();
            } catch (Throwable ignored) {}
        }
    }
}
