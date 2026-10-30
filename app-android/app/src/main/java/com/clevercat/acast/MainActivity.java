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
    private ListView lvDevices;

    private boolean isCapturing = false;
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
        lvDevices = findViewById(R.id.lv_devices);

        deviceAdapter = new ArrayAdapter<>(this, android.R.layout.simple_list_item_1, deviceList);
        lvDevices.setAdapter(deviceAdapter);

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

        lvDevices.setOnItemClickListener((parent, view, position, id) -> {
            String selected = deviceList.get(position);
            String controlUrl = selected;
            int arrowIdx = selected.lastIndexOf(" -> ");
            if (arrowIdx != -1) {
                controlUrl = selected.substring(arrowIdx + 4).trim();
            }
            String myIp = getLocalIpAddress(this);
            String streamUrl = "http://" + myIp + ":8088/live.ts";
            DlnaSender.playMediaOnTv(controlUrl, streamUrl);
            Toast.makeText(this, "已发起投屏！实时音画流: " + streamUrl, Toast.LENGTH_LONG).show();
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
                Toast.makeText(this, "用户未授予录屏权限", Toast.LENGTH_SHORT).show();
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
            tvStatus.setText("正在投屏：USB/Wi-Fi 极低延迟反控与 DLNA 实时流已开启");
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
        btnToggleCapture.setText(R.string.btn_start_capture);
        tvStatus.setText(R.string.status_ready);
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
