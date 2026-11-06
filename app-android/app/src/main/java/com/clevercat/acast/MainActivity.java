package com.clevercat.acast;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.media.projection.MediaProjectionManager;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.ListAdapter;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.google.android.material.button.MaterialButton;

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
    private static final int REQUEST_CAMERA_PERMISSION = 2003;

    private MaterialButton btnToggleCapture;
    private MaterialButton btnToggleCamera;
    private android.widget.LinearLayout layoutCameraControls;
    private Button btnSwitchCamera;
    private Button btnToggleTorch;
    private Button btnCameraRes;
    private android.view.TextureView cameraPreviewView;
    private MaterialButton btnAccessibility;
    private MaterialButton btnKeepAlive;
    private Button btnScanDevices;
    private Button btnCheckUpdate;
    private TextView tvStatus;
    private TextView tvDeviceHeader;
    private ListView lvDevices;

    private boolean isCapturing = false;
    private int currentCameraRes = 1080;
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

        // 投屏主界面保持屏幕常亮
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        setContentView(R.layout.activity_main);

        btnToggleCapture = findViewById(R.id.btn_toggle_capture);
        btnToggleCamera = findViewById(R.id.btn_toggle_camera);
        layoutCameraControls = findViewById(R.id.layout_camera_controls);
        btnSwitchCamera = findViewById(R.id.btn_switch_camera);
        btnToggleTorch = findViewById(R.id.btn_toggle_torch);
        btnCameraRes = findViewById(R.id.btn_camera_res);
        cameraPreviewView = findViewById(R.id.camera_preview_view);
        btnAccessibility = findViewById(R.id.btn_accessibility);
        btnKeepAlive = findViewById(R.id.btn_keep_alive);
        btnScanDevices = findViewById(R.id.btn_scan_tv);
        btnCheckUpdate = findViewById(R.id.btn_check_update);
        tvStatus = findViewById(R.id.tv_status);
        tvDeviceHeader = findViewById(R.id.tv_device_header);
        lvDevices = findViewById(R.id.lv_devices);

        TextView tvAppVersion = findViewById(R.id.tv_app_version);
        if (tvAppVersion != null) {
            try {
                String versionName = getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
                tvAppVersion.setText("v" + versionName);
            } catch (Throwable ignored) {
                tvAppVersion.setText("v0.4.5");
            }
        }

        // 点击无障碍按钮，一键直达系统无障碍设置开启反控
        btnAccessibility.setOnClickListener(v -> {
            try {
                Intent intent = new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS);
                startActivity(intent);
                Toast.makeText(this, "请在已安装的服务中点击【ACast 投屏】，开启无障碍权限即可支持电脑鼠标反控！", Toast.LENGTH_LONG).show();
            } catch (Throwable t) {
                Toast.makeText(this, "打开无障碍设置异常，请手动前往手机设置开启", Toast.LENGTH_SHORT).show();
            }
        });

        // 点击后台保活与防杀按钮，弹出保活指引与一键忽略电池优化授权
        btnKeepAlive.setOnClickListener(v -> KeepAliveHelper.showKeepAliveDialog(this, this::updateKeepAliveUi));

        deviceAdapter = new ArrayAdapter<String>(this, R.layout.item_device, deviceList) {
            @NonNull
            @Override
            public View getView(int position, @Nullable View convertView, @NonNull ViewGroup parent) {
                View view = convertView;
                if (view == null) {
                    view = LayoutInflater.from(getContext()).inflate(R.layout.item_device, parent, false);
                }
                String item = getItem(position);
                TextView tvIcon = view.findViewById(R.id.tv_device_icon);
                TextView tvName = view.findViewById(R.id.tv_device_name);
                TextView tvSub = view.findViewById(R.id.tv_device_sub);
                TextView tvAction = view.findViewById(R.id.tv_device_action);

                if (item != null) {
                    if (item.startsWith("💻 ")) {
                        tvIcon.setText("💻");
                        String content = item.substring(2).trim();
                        int lParen = content.lastIndexOf('(');
                        int rParen = content.lastIndexOf(')');
                        if (lParen != -1 && rParen != -1) {
                            tvName.setText(content.substring(0, lParen).trim());
                            tvSub.setText(content.substring(lParen + 1, rParen).trim() + " · 电脑控制端 (音画/反控就绪)");
                        } else {
                            tvName.setText(content);
                            tvSub.setText("局域网电脑控制端");
                        }
                        tvAction.setText("直连");
                        tvAction.setTextColor(0xFF2563EB);
                    } else if (item.startsWith("📺 ")) {
                        tvIcon.setText("📺");
                        String content = item.substring(2).trim();
                        int arrowIdx = content.lastIndexOf(" -> ");
                        if (arrowIdx != -1) {
                            tvName.setText(content.substring(0, arrowIdx).trim());
                            tvSub.setText(content.substring(arrowIdx + 4).trim() + " · DLNA 大屏电视");
                        } else {
                            tvName.setText(content);
                            tvSub.setText("DLNA 大屏设备");
                        }
                        tvAction.setText("投屏");
                        tvAction.setTextColor(0xFFD97706);
                    } else {
                        tvIcon.setText("📱");
                        tvName.setText(item);
                        tvSub.setText("局域网设备");
                        tvAction.setText("连接");
                        tvAction.setTextColor(0xFF2563EB);
                    }
                }
                return view;
            }
        };
        lvDevices.setAdapter(deviceAdapter);

        // 初始化界面状态
        updateStatusUi();
        updateAccessibilityUi();
        updateKeepAliveUi();

        // 预先启动本地推流与反控通信端口，随时响应局域网大屏和电脑连接
        try {
            LocalHttpTsServer.getInstance().startServer(8088);
            FastMirrorSender.getInstance().setContext(this);
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

        btnToggleCamera.setOnClickListener(v -> {
            if (CameraStreamingHelper.getInstance().isStreaming()) {
                stopCameraStream();
            } else {
                checkCameraPermissionAndStart();
            }
        });

        btnSwitchCamera.setOnClickListener(v -> {
            CameraStreamingHelper.getInstance().switchCamera();
            Toast.makeText(this, "正在切换" + (CameraStreamingHelper.getInstance().isFrontCamera() ? "前置" : "后置") + "摄像头...", Toast.LENGTH_SHORT).show();
        });

        btnToggleTorch.setOnClickListener(v -> {
            CameraStreamingHelper.getInstance().toggleTorch();
            btnToggleTorch.setText(CameraStreamingHelper.getInstance().isTorchOn() ? "💡 灯开" : "💡 灯关");
        });

        btnCameraRes.setOnClickListener(v -> {
            currentCameraRes = (currentCameraRes == 1080) ? 720 : 1080;
            btnCameraRes.setText("⚙️ " + currentCameraRes + "P");
            if (CameraStreamingHelper.getInstance().isStreaming()) {
                Toast.makeText(this, "分辨率切换为 " + currentCameraRes + "P，正在重置摄像头流...", Toast.LENGTH_SHORT).show();
                stopCameraStream();
                startCameraStream();
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

    private void adjustListViewHeight(ListView listView) {
        if (listView == null) return;
        ListAdapter listAdapter = listView.getAdapter();
        if (listAdapter == null) return;
        int totalHeight = 0;
        int count = listAdapter.getCount();
        int widthSpec = View.MeasureSpec.makeMeasureSpec(
                listView.getWidth() > 0 ? listView.getWidth() : getResources().getDisplayMetrics().widthPixels,
                View.MeasureSpec.AT_MOST);
        int heightSpec = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED);
        for (int i = 0; i < count; i++) {
            View listItem = listAdapter.getView(i, null, listView);
            listItem.measure(widthSpec, heightSpec);
            totalHeight += listItem.getMeasuredHeight();
        }
        ViewGroup.LayoutParams params = listView.getLayoutParams();
        params.height = totalHeight + (listView.getDividerHeight() * Math.max(0, count - 1));
        listView.setLayoutParams(params);
        listView.requestLayout();
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
        if (lvDevices != null) {
            lvDevices.post(() -> adjustListViewHeight(lvDevices));
        }
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
        } else if (requestCode == REQUEST_CAMERA_PERMISSION) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startCameraStream();
            } else {
                Toast.makeText(this, "需开启相机权限才能使用摄像头模式", Toast.LENGTH_SHORT).show();
            }
        }
    }

    private void checkCameraPermissionAndStart() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, new String[]{Manifest.permission.CAMERA}, REQUEST_CAMERA_PERMISSION);
        } else {
            startCameraStream();
        }
    }

    private void startCameraStream() {
        int width = (currentCameraRes == 1080) ? 1920 : 1280;
        int height = (currentCameraRes == 1080) ? 1080 : 720;

        android.view.Surface previewSurface = null;
        if (cameraPreviewView != null && cameraPreviewView.isAvailable()) {
            previewSurface = new android.view.Surface(cameraPreviewView.getSurfaceTexture());
        }

        CameraStreamingHelper.getInstance().startCamera(
                this,
                previewSurface,
                width,
                height,
                false, // 默认后置高清摄像头
                new CameraStreamingHelper.CameraListener() {
                    @Override
                    public void onCameraStarted(int w, int h, boolean isFront) {
                        runOnUiThread(() -> {
                            btnToggleCamera.setText("⏹️ 关闭 Android 摄像头");
                            btnToggleCamera.setBackgroundTintList(ColorStateList.valueOf(0xFFFEE2E2));
                            btnToggleCamera.setTextColor(0xFFDC2626);
                            layoutCameraControls.setVisibility(View.VISIBLE);
                            cameraPreviewView.setVisibility(View.VISIBLE);
                            updateStatusUi();
                        });
                    }

                    @Override
                    public void onCameraStopped() {
                        runOnUiThread(() -> {
                            btnToggleCamera.setText("📷 启用 Android 摄像头 (Mac 虚拟摄像头)");
                            btnToggleCamera.setBackgroundTintList(ColorStateList.valueOf(0xFFCCFBF1));
                            btnToggleCamera.setTextColor(0xFF0F766E);
                            layoutCameraControls.setVisibility(View.GONE);
                            cameraPreviewView.setVisibility(View.GONE);
                            updateStatusUi();
                        });
                    }

                    @Override
                    public void onError(String message) {
                        runOnUiThread(() -> {
                            Toast.makeText(MainActivity.this, "摄像头异常: " + message, Toast.LENGTH_LONG).show();
                            stopCameraStream();
                        });
                    }
                }
        );
    }

    private void stopCameraStream() {
        CameraStreamingHelper.getInstance().stopCamera();
    }

    private void launchMediaProjectionPrompt() {
        try {
            MediaProjectionManager manager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            if (manager != null) {
                Intent captureIntent;
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    // Android 14+ 强制指定捕获整个默认屏幕，防止系统默认仅录制单个应用导致状态栏/通知栏/控制中心菜单被系统隐私过滤
                    android.media.projection.MediaProjectionConfig config =
                            android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay();
                    captureIntent = manager.createScreenCaptureIntent(config);
                    Log.i(TAG, "已为 Android 14+ 配置 createConfigForDefaultDisplay 捕获完整系统屏幕(包含状态栏/通知栏/控制中心)");
                } else {
                    captureIntent = manager.createScreenCaptureIntent();
                }
                startActivityForResult(captureIntent, REQUEST_MEDIA_PROJECTION);
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
        String streamUrl = "http://" + myIp + ":8088/live";
        DlnaSender.playMediaOnTv(deviceName, controlUrl, streamUrl);
        Toast.makeText(this, "已发起投屏至【" + deviceName + "】！", Toast.LENGTH_SHORT).show();
        tvStatus.setText("✓ 正在向【" + deviceName + "】投屏中 (实时音画传输中)");
    }

    private void updateStatusUi() {
        String ip = getLocalIpAddress(this);
        boolean isCamera = CameraStreamingHelper.getInstance().isStreaming();

        if (isCapturing) {
            btnToggleCapture.setText("⏹️ 停止投屏");
            btnToggleCapture.setBackgroundTintList(ColorStateList.valueOf(0xFFDC2626)); // 停止红
            if (tvDeviceHeader != null) {
                tvDeviceHeader.setText("💻 目标设备 (电脑控制端 / 大屏电视)");
            }
        } else {
            btnToggleCapture.setText("🚀 开启屏幕投屏 (超低延迟)");
            btnToggleCapture.setBackgroundTintList(ColorStateList.valueOf(0xFF2563EB)); // 科技蓝
            if (tvDeviceHeader != null) {
                tvDeviceHeader.setText("💻 目标设备 (⚠️ 请先开启上方投屏)");
            }
        }

        if (isCapturing && isCamera) {
            tvStatus.setText("✓ 投屏与摄像头并发运行中 (双流物理独立隔离)\n📡 手机屏幕直播: http://" + ip + ":8088/screen\n📷 摄像头专属流: http://" + ip + ":8088/camera (OBS 推荐/毫秒级无串流)\n电脑控制端可自动反控，大屏直连就绪");
            tvStatus.setTextColor(0xFF16A34A);
        } else if (isCapturing) {
            tvStatus.setText("✓ 投屏进行中 (本机 IP: " + ip + ")\n📡 手机屏幕直播流: http://" + ip + ":8088/screen (或 /live)\n电脑控制端可自动发现直连，或点击下方设备连接");
            tvStatus.setTextColor(0xFF16A34A); // 翠绿色
        } else if (isCamera) {
            tvStatus.setText("📷 Android 摄像头推流中 (Mac 虚拟相机已联动)\n⚡ 专属超低延迟流 (OBS 推荐): http://" + ip + ":8088/camera\n📡 通用直播流地址: http://" + ip + ":8088/live\n已启用独立推流通道，绝不混入投屏画面！");
            tvStatus.setTextColor(0xFF0D9488); // Teal 色
        } else {
            tvStatus.setText("● 本地推流服务就绪 (端口 8088 / 19999)\n📡 直播流地址: http://" + ip + ":8088/live\n点击下方按钮立即开启手机屏幕投屏");
            tvStatus.setTextColor(0xFF2563EB); // 科技蓝
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
    protected void onResume() {
        super.onResume();
        updateAccessibilityUi();
        updateKeepAliveUi();
    }

    private void updateKeepAliveUi() {
        if (btnKeepAlive == null) return;
        boolean isIgnoring = KeepAliveHelper.isIgnoringBatteryOptimizations(this);
        if (isIgnoring) {
            btnKeepAlive.setText("✓ 后台保活与防杀：已配置无限制 (锁屏防断连)");
            btnKeepAlive.setTextColor(0xFF16A34A); // 绿色
            btnKeepAlive.setStrokeColor(ColorStateList.valueOf(0xFF86EFAC));
        } else {
            btnKeepAlive.setText("⚡ 后台保活与防杀：未开启白名单 (点击配置)");
            btnKeepAlive.setTextColor(0xFFD97706); // 警示橙色
            btnKeepAlive.setStrokeColor(ColorStateList.valueOf(0xFFFCD34D));
        }
    }

    private void updateAccessibilityUi() {
        if (btnAccessibility == null) return;
        boolean enabled = ControlAccessibilityService.isAvailable() ||
                ControlAccessibilityService.isAccessibilitySettingsOn(this);
        if (enabled) {
            btnAccessibility.setText("✓ 电脑鼠标反控：已就绪 (支持鼠标/打字/触控)");
            btnAccessibility.setTextColor(0xFF16A34A); // 绿色
            btnAccessibility.setStrokeColor(ColorStateList.valueOf(0xFF86EFAC));
        } else {
            btnAccessibility.setText("🖱️ 电脑鼠标反控：未开启 (点击开启无障碍权限)");
            btnAccessibility.setTextColor(0xFFD97706); // 警示橙色
            btnAccessibility.setStrokeColor(ColorStateList.valueOf(0xFFFCD34D));
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        CameraStreamingHelper.getInstance().stopCamera();
        PeerDiscoveryManager.getInstance().stop();
        if (multicastLock != null && multicastLock.isHeld()) {
            multicastLock.release();
        }
    }
}
