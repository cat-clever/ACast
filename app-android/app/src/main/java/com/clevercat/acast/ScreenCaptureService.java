package com.clevercat.acast;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Surface;
import android.view.WindowManager;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import java.nio.ByteBuffer;

public class ScreenCaptureService extends Service {

    private static final String TAG = "ScreenCaptureService";
    private static final String CHANNEL_ID = "ACastScreenCaptureChannel";
    private static final int NOTIFICATION_ID = 2026;

    private MediaProjection mediaProjection;
    private VirtualDisplay virtualDisplay;
    private MediaCodec videoCodec;
    private Surface inputSurface;
    private AudioCaptureHelper audioCaptureHelper;

    private boolean isEncoding = false;
    private Thread encoderThread;
    private PowerManager.WakeLock wakeLock;
    private PowerManager.WakeLock screenWakeLock;
    private WifiManager.WifiLock wifiLock;

    private int cachedWidth = 1080;
    private int cachedHeight = 1920;
    private int cachedDensity = 320;
    private BroadcastReceiver screenStateReceiver;
    private boolean isMediaProjectionStopped = false;

    private static int sResultCode = 0;
    private static Intent sResultData = null;
    private static ScreenCaptureService sInstance;

    public static void requestKeyFrame() {
        if (sInstance != null && sInstance.videoCodec != null && sInstance.isEncoding) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                    android.os.Bundle params = new android.os.Bundle();
                    params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
                    sInstance.videoCodec.setParameters(params);
                    Log.i(TAG, "已向硬件编码器请求即时刷新关键帧 (I-Frame/IDR)");
                }
            } catch (Throwable t) {
                Log.w(TAG, "requestKeyFrame 异常: " + t.getMessage());
            }
        }
    }

    public static void requestKeyFrameDelayed() {
        requestKeyFrame();
        new Handler(Looper.getMainLooper()).postDelayed(ScreenCaptureService::requestKeyFrame, 100);
        new Handler(Looper.getMainLooper()).postDelayed(ScreenCaptureService::requestKeyFrame, 300);
    }

    /**
     * 当屏幕点亮或解锁时，重新唤醒 Surface 并高频下发关键帧，根治锁屏黑屏
     */
    public static void onScreenUnlocked() {
        if (sInstance != null) {
            sInstance.handleScreenUnlockedInternal();
        }
    }

    private synchronized void handleScreenUnlockedInternal() {
        Log.i(TAG, "✓ 收到亮屏/解锁唤醒事件，检查前台投屏管线与 VirtualDisplay 状态...");

        // 重点：Android 14+ 严格禁止单个 MediaProjection 重复创建 VirtualDisplay，
        // 因此绝对不能主动 release 现存 VirtualDisplay 实例，只需确保绑定唤醒
        if (virtualDisplay != null && inputSurface != null) {
            try {
                virtualDisplay.setSurface(inputSurface);
            } catch (Throwable ignored) {}
            Log.i(TAG, "✓ 现有 VirtualDisplay 正常就绪，重新激活 Surface 映射");
        } else {
            createOrResetVirtualDisplay();
        }

        // 连续下发 3 次关键帧请求，确保亮屏解锁后画面秒级恢复显示
        requestKeyFrameDelayed();
    }

    public synchronized void createOrResetVirtualDisplay() {
        if (mediaProjection == null || inputSurface == null) return;
        try {
            if (virtualDisplay != null) {
                // 已经存在 VirtualDisplay，切勿 release 重建，防止触发系统安全单次限制
                try {
                    virtualDisplay.setSurface(inputSurface);
                } catch (Throwable ignored) {}
                requestKeyFrameDelayed();
                return;
            }

            VirtualDisplay.Callback callback = new VirtualDisplay.Callback() {
                @Override
                public void onPaused() {
                    super.onPaused();
                    Log.i(TAG, "VirtualDisplay 已暂停 (锁屏息屏)");
                }

                @Override
                public void onResumed() {
                    super.onResumed();
                    Log.i(TAG, "VirtualDisplay 已恢复 (亮屏解锁)，立即触发关键帧刷新");
                    requestKeyFrameDelayed();
                }

                @Override
                public void onStopped() {
                    super.onStopped();
                    Log.w(TAG, "VirtualDisplay 已停止");
                }
            };

            virtualDisplay = mediaProjection.createVirtualDisplay(
                    "ACastVirtualDisplay",
                    cachedWidth, cachedHeight, cachedDensity,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    inputSurface, callback, new Handler(Looper.getMainLooper())
            );
            Log.i(TAG, "✓ VirtualDisplay 已成功建立镜像绑定 (" + cachedWidth + "x" + cachedHeight + ")");

            requestKeyFrameDelayed();
        } catch (Throwable t) {
            Log.e(TAG, "createOrResetVirtualDisplay 失败: " + t.getMessage(), t);
        }
    }

    private void registerScreenStateReceiver() {
        if (screenStateReceiver != null) return;
        screenStateReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (intent == null) return;
                String action = intent.getAction();
                if (Intent.ACTION_SCREEN_ON.equals(action) || Intent.ACTION_USER_PRESENT.equals(action)) {
                    Log.i(TAG, "✓ 检测到手机屏幕亮屏/解锁 (" + action + ")，执行 VirtualDisplay 唤醒重绑并刷新关键帧...");
                    onScreenUnlocked();
                } else if (Intent.ACTION_SCREEN_OFF.equals(action)) {
                    Log.i(TAG, "检测到手机锁屏息屏 (ACTION_SCREEN_OFF)");
                }
            }
        };
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        filter.addAction(Intent.ACTION_USER_PRESENT);
        registerReceiver(screenStateReceiver, filter);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        sInstance = this;
        createNotificationChannel();

        Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("ACast 投屏服务运行中")
                .setContentText("正在传输屏幕与音频，支持电脑端一键反控与大屏投屏")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .build();

        // Android 14 (API 34) 及 Android 10+ 显式指定 FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }

        try {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            if (pm != null) {
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "acast:screencapture_wakelock");
                wakeLock.acquire();

                // 强制激活屏幕常亮锁，防止 1 分钟系统超时息屏导致 VirtualDisplay 停止推流
                screenWakeLock = pm.newWakeLock(
                        PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP | PowerManager.ON_AFTER_RELEASE,
                        "acast:screencapture_screenon"
                );
                screenWakeLock.acquire();
                Log.i(TAG, "✓ 投屏屏幕常亮唤醒锁已激活");
            }
        } catch (Throwable t) {
            Log.w(TAG, "获取 WakeLock 异常: " + t.getMessage());
        }

        try {
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "acast:screencapture_wifilock");
                wifiLock.setReferenceCounted(false);
                wifiLock.acquire();
                Log.i(TAG, "✓ 投屏高性能 WiFi 保持锁已激活 (锁屏防断流)");
            }
        } catch (Throwable t) {
            Log.w(TAG, "获取 WifiLock 异常: " + t.getMessage());
        }

        // 投屏开始：激活全局屏幕常亮保护，防止手机自动休眠锁屏
        ControlAccessibilityService.setKeepScreenOn(true);

        // 注册亮屏、锁屏与解锁广播监听，根治解锁后黑屏
        registerScreenStateReceiver();

        try {
            // 启动 FastMirror 桌面反控通信服务
            FastMirrorSender.getInstance().startServer(19999);
            // 启动 DLNA / Cast / AirPlay 实时流服务器
            LocalHttpTsServer.getInstance().startServer(8088);
        } catch (Throwable t) {
            Log.e(TAG, "启动本地后台推流服务异常: " + t.getMessage(), t);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            int resultCode = intent.getIntExtra("resultCode", intent.getIntExtra("code", 0));
            Intent data = intent.getParcelableExtra("data");
            if (resultCode != 0 && data != null) {
                sResultCode = resultCode;
                sResultData = data;
                isMediaProjectionStopped = false;

                MediaProjectionManager manager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
                if (manager != null) {
                    try {
                        mediaProjection = manager.getMediaProjection(resultCode, data);
                        if (mediaProjection != null) {
                            Log.i(TAG, "成功获取 MediaProjection 权限，开始启动硬件编码器...");
                            startEncoding();
                        } else {
                            Log.e(TAG, "获取 mediaProjection 结果为空！");
                        }
                    } catch (Throwable t) {
                        Log.e(TAG, "获取 MediaProjection 失败: " + t.getMessage(), t);
                    }
                }
            } else {
                Log.w(TAG, "onStartCommand 未获取到有效的 resultCode 或 data! resultCode=" + resultCode + ", data=" + data);
            }
        }
        return START_STICKY;
    }

    private void startEncoding() {
        if (mediaProjection == null) return;

        // Android 14+ 要求在 createVirtualDisplay 前注册回调
        mediaProjection.registerCallback(new MediaProjection.Callback() {
            @Override
            public void onStop() {
                super.onStop();
                Log.w(TAG, "MediaProjection 停止回调触发 (系统息屏锁屏挂起，保持前台服务常驻保活，等待亮屏解锁恢复...)");
                isMediaProjectionStopped = true;
                if (virtualDisplay != null) {
                    try {
                        virtualDisplay.setSurface(null);
                        virtualDisplay.release();
                    } catch (Throwable ignored) {}
                    virtualDisplay = null;
                }
                // 切勿调用 stopSelf()！保持 Service 强保活状态
            }
        }, new Handler(Looper.getMainLooper()));

        WindowManager wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        DisplayMetrics metrics = new DisplayMetrics();
        if (wm != null && wm.getDefaultDisplay() != null) {
            wm.getDefaultDisplay().getRealMetrics(metrics);
        } else {
            metrics = getResources().getDisplayMetrics();
        }

        int origW = metrics.widthPixels > 0 ? metrics.widthPixels : 1080;
        int origH = metrics.heightPixels > 0 ? metrics.heightPixels : 1920;
        int density = metrics.densityDpi > 0 ? metrics.densityDpi : 320;

        // 自适应缩放分辨率：限制宽最高 1080，高最高 1920，保持比例并做 16 字节对齐，防止某些芯片硬编码器崩溃
        float scale = 1.0f;
        int maxDim = Math.max(origW, origH);
        if (maxDim > 1920) {
            scale = 1920.0f / maxDim;
        }
        int encW = ((int) (origW * scale) / 16) * 16;
        int encH = ((int) (origH * scale) / 16) * 16;
        if (encW <= 0) encW = 720;
        if (encH <= 0) encH = 1280;

        Log.i(TAG, "屏幕原始分辨率: " + origW + "x" + origH + ", 编码分辨率: " + encW + "x" + encH);

        boolean initSuccess = initCodec(encW, encH, density, 5000000);
        // 若首选分辨率初始化失败，回退到通用的 720P 安全配置重试
        if (!initSuccess) {
            Log.w(TAG, "首选编码分辨率失败，尝试回退到标准 720x1280 分辨率...");
            initSuccess = initCodec(720, 1280, density, 3000000);
        }

        if (!initSuccess) {
            Log.e(TAG, "硬件编码器均无法初始化，请检查当前设备编解码驱动！");
            return;
        }

        // 启动音频捕获（包裹在 try-catch 中，即使音频捕获受限也不影响屏幕投屏）
        try {
            audioCaptureHelper = new AudioCaptureHelper();
            audioCaptureHelper.startCapture(mediaProjection, (buffer, size) -> {
                FastMirrorSender.getInstance().sendAudio(buffer, size);
                LocalHttpTsServer.getInstance().pushAudio(buffer, size);
            });
        } catch (Throwable t) {
            Log.w(TAG, "音频采集开启失败（已静默降级为纯画面投屏）: " + t.getMessage());
        }
    }

    private boolean initCodec(int width, int height, int density, int bitRate) {
        try {
            if (videoCodec != null) {
                try {
                    videoCodec.stop();
                    videoCodec.release();
                } catch (Throwable ignored) {}
                videoCodec = null;
            }

            MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 30);
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                // 画面静止时每隔 50ms (20fps) 重复上一帧，保证实时流恒定输出，首屏秒开不卡顿
                format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 50000L);
            }

            videoCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            videoCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            inputSurface = videoCodec.createInputSurface();
            videoCodec.start();

            cachedWidth = width;
            cachedHeight = height;
            cachedDensity = density;

            createOrResetVirtualDisplay();

            isEncoding = true;
            encoderThread = new Thread(this::drainEncoder, "ACastEncoderThread");
            encoderThread.start();
            return true;

        } catch (Throwable t) {
            Log.e(TAG, "initCodec 失败 (" + width + "x" + height + "): " + t.getMessage(), t);
            if (videoCodec != null) {
                try {
                    videoCodec.release();
                } catch (Throwable ignored) {}
                videoCodec = null;
            }
            return false;
        }
    }

    private void drainEncoder() {
        MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();
        while (isEncoding) {
            try {
                if (videoCodec == null) break;
                int outputBufferIndex = videoCodec.dequeueOutputBuffer(bufferInfo, 10000);
                if (outputBufferIndex >= 0) {
                    ByteBuffer outputBuffer = videoCodec.getOutputBuffer(outputBufferIndex);
                    if (outputBuffer != null && bufferInfo.size > 0) {
                        byte[] outData = new byte[bufferInfo.size];
                        outputBuffer.get(outData);

                        if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                            // 捕获编码器初始化的 SPS / PPS 配置信息并同步给 HLS 与 FastMirror
                            LocalHttpTsServer.getInstance().setSpsPps(outData);
                            FastMirrorSender.getInstance().setSpsPps(outData);
                        } else {
                            boolean isKeyFrame = (bufferInfo.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;

                            // 分发至自研 FastMirror 极速反控通道
                            FastMirrorSender.getInstance().sendVideo(outData, isKeyFrame, bufferInfo.presentationTimeUs);
                            // 分发至 DLNA 实时 TS 流
                            LocalHttpTsServer.getInstance().pushVideo(outData, isKeyFrame, bufferInfo.presentationTimeUs);
                        }
                    }
                    videoCodec.releaseOutputBuffer(outputBufferIndex, false);
                }
            } catch (Throwable t) {
                Log.w(TAG, "drainEncoder 循环异常: " + t.getMessage());
                break;
            }
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "ACast 投屏通知",
                    NotificationManager.IMPORTANCE_LOW
            );
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        sInstance = null;
        isEncoding = false;
        if (encoderThread != null) {
            try {
                encoderThread.join(300);
            } catch (Throwable ignored) {}
        }
        if (audioCaptureHelper != null) {
            try {
                audioCaptureHelper.stopCapture();
            } catch (Throwable ignored) {}
        }
        if (virtualDisplay != null) {
            try {
                virtualDisplay.release();
            } catch (Throwable ignored) {}
            virtualDisplay = null;
        }
        if (videoCodec != null) {
            try {
                videoCodec.stop();
                videoCodec.release();
            } catch (Throwable ignored) {}
            videoCodec = null;
        }
        if (mediaProjection != null) {
            try {
                mediaProjection.stop();
            } catch (Throwable ignored) {}
            mediaProjection = null;
        }
        // 注销屏幕状态广播接收器
        if (screenStateReceiver != null) {
            try {
                unregisterReceiver(screenStateReceiver);
            } catch (Throwable ignored) {}
            screenStateReceiver = null;
        }

        // 解除屏幕常亮保护
        ControlAccessibilityService.setKeepScreenOn(false);

        // 释放屏幕常亮 WakeLock 与 CPU WakeLock
        if (screenWakeLock != null && screenWakeLock.isHeld()) {
            try {
                screenWakeLock.release();
            } catch (Throwable ignored) {}
            screenWakeLock = null;
        }
        if (wakeLock != null && wakeLock.isHeld()) {
            try {
                wakeLock.release();
            } catch (Throwable ignored) {}
            wakeLock = null;
        }
        if (wifiLock != null && wifiLock.isHeld()) {
            try {
                wifiLock.release();
            } catch (Throwable ignored) {}
            wifiLock = null;
        }

        // 注意：FastMirrorSender 与 LocalHttpTsServer 属于全局网络通信管道，
        // 保持长驻，切勿随 ScreenCaptureService 销毁而暴力关闭，防止控制端断开连接。
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
