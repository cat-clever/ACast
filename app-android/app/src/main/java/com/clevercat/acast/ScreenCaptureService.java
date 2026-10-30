package com.clevercat.acast;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.IBinder;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Surface;
import android.view.WindowManager;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import java.io.IOException;
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

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("ACast 投屏服务运行中")
                .setContentText("正在传输屏幕与音频，USB/Wi-Fi 反控监听端口 19999")
                .setSmallIcon(android.R.drawable.ic_menu_slideshow)
                .build();
        startForeground(NOTIFICATION_ID, notification);

        // 启动 FastMirror 桌面反控通信服务
        FastMirrorSender.getInstance().startServer(19999);
        // 启动 DLNA / Cast / AirPlay 实时流服务器
        LocalHttpTsServer.getInstance().startServer(8088);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            int resultCode = intent.getIntExtra("resultCode", 0);
            Intent data = intent.getParcelableExtra("data");
            if (resultCode != 0 && data != null) {
                MediaProjectionManager manager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
                if (manager != null) {
                    mediaProjection = manager.getMediaProjection(resultCode, data);
                    startEncoding();
                }
            }
        }
        return START_STICKY;
    }

    private void startEncoding() {
        WindowManager wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        DisplayMetrics metrics = new DisplayMetrics();
        wm.getDefaultDisplay().getRealMetrics(metrics);

        int width = metrics.widthPixels;
        int height = metrics.heightPixels;
        int density = metrics.densityDpi;

        // 对齐 16 字节
        width = (width / 16) * 16;
        height = (height / 16) * 16;

        try {
            MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            format.setInteger(MediaFormat.KEY_BIT_RATE, 6000000); // 6 Mbps
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 60);
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);

            videoCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            videoCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            inputSurface = videoCodec.createInputSurface();
            videoCodec.start();

            virtualDisplay = mediaProjection.createVirtualDisplay(
                    "ACastVirtualDisplay",
                    width, height, density,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    inputSurface, null, null
            );

            isEncoding = true;
            encoderThread = new Thread(this::drainEncoder);
            encoderThread.start();

            // 启动音频捕获
            audioCaptureHelper = new AudioCaptureHelper();
            audioCaptureHelper.startCapture(mediaProjection, (buffer, size) -> {
                FastMirrorSender.getInstance().sendAudio(buffer, size);
                LocalHttpTsServer.getInstance().pushAudio(buffer, size);
            });

        } catch (IOException e) {
            Log.e(TAG, "创建硬件编码器失败: " + e.getMessage());
        }
    }

    private void drainEncoder() {
        MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();
        while (isEncoding) {
            int outputBufferIndex = videoCodec.dequeueOutputBuffer(bufferInfo, 10000);
            if (outputBufferIndex >= 0) {
                ByteBuffer outputBuffer = videoCodec.getOutputBuffer(outputBufferIndex);
                if (outputBuffer != null && bufferInfo.size > 0) {
                    byte[] outData = new byte[bufferInfo.size];
                    outputBuffer.get(outData);

                    boolean isKeyFrame = (bufferInfo.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;

                    // 分发至自研 FastMirror 极速反控通道
                    FastMirrorSender.getInstance().sendVideo(outData, isKeyFrame, bufferInfo.presentationTimeUs);
                    // 分发至 DLNA 实时 TS 流
                    LocalHttpTsServer.getInstance().pushVideo(outData, isKeyFrame, bufferInfo.presentationTimeUs);
                }
                videoCodec.releaseOutputBuffer(outputBufferIndex, false);
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
        isEncoding = false;
        if (encoderThread != null) {
            try {
                encoderThread.join(500);
            } catch (InterruptedException ignored) {}
        }
        if (audioCaptureHelper != null) {
            audioCaptureHelper.stopCapture();
        }
        if (videoCodec != null) {
            try {
                videoCodec.stop();
                videoCodec.release();
            } catch (Exception ignored) {}
        }
        if (virtualDisplay != null) {
            virtualDisplay.release();
        }
        if (mediaProjection != null) {
            mediaProjection.stop();
        }
        FastMirrorSender.getInstance().stopServer();
        LocalHttpTsServer.getInstance().stopServer();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}

