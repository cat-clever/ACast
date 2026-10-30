package com.clevercat.acast;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import java.util.ArrayList;

public class MainActivity extends AppCompatActivity {

    private static final int REQUEST_MEDIA_PROJECTION = 1001;

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
        // 启动时后台静默检查
        performUpdateCheck(false);

        // 允许组播接收 SSDP 广播
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifi != null) {
            multicastLock = wifi.createMulticastLock("ACastMulticastLock");
            multicastLock.acquire();
        }

        btnToggleCapture.setOnClickListener(v -> {
            if (!isCapturing) {
                MediaProjectionManager manager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
                if (manager != null) {
                    startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_MEDIA_PROJECTION);
                }
            } else {
                stopScreenCapture();
            }
        });

        btnScanTv.setOnClickListener(v -> {
            deviceList.clear();
            deviceAdapter.notifyDataSetChanged();
            Toast.makeText(this, "正在搜索局域网大屏 (DLNA / Cast / AirPlay)...", Toast.LENGTH_SHORT).show();
            // 启动后台 SSDP 扫描
            DlnaSender.discoverDevices(this, (name, controlUrl) -> runOnUiThread(() -> {
                String item = name + " (" + controlUrl + ")";
                if (!deviceList.contains(item)) {
                    deviceList.add(item);
                    deviceAdapter.notifyDataSetChanged();
                }
            }));
        });

        lvDevices.setOnItemClickListener((parent, view, position, id) -> {
            String selected = deviceList.get(position);
            Toast.makeText(this, "已向电视发起投屏: " + selected, Toast.LENGTH_LONG).show();
        });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_MEDIA_PROJECTION) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                startScreenCapture(resultCode, data);
            } else {
                Toast.makeText(this, "用户取消了录屏授权", Toast.LENGTH_SHORT).show();
            }
        }
    }

    private void startScreenCapture(int resultCode, Intent data) {
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
        tvStatus.setText("正在投屏：极低延迟 USB/Wi-Fi 反控与 DLNA 实时流已开启");
    }

    private void stopScreenCapture() {
        Intent serviceIntent = new Intent(this, ScreenCaptureService.class);
        stopService(serviceIntent);

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
            multicastLock.release();
        }
    }
}

