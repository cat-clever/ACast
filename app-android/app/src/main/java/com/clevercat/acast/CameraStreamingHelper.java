package com.clevercat.acast;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.ImageFormat;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CameraMetadata;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.util.Size;
import android.view.Surface;

import androidx.annotation.NonNull;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

public class CameraStreamingHelper {

    private static final String TAG = "CameraStreamingHelper";
    private static final CameraStreamingHelper INSTANCE = new CameraStreamingHelper();

    public static CameraStreamingHelper getInstance() {
        return INSTANCE;
    }

    public interface CameraListener {
        void onCameraStarted(int width, int height, boolean isFrontCamera);
        void onCameraStopped();
        void onError(String message);
    }

    private Context appContext;
    private CameraManager cameraManager;
    private CameraDevice cameraDevice;
    private CameraCaptureSession captureSession;
    private CaptureRequest.Builder previewRequestBuilder;

    private MediaCodec videoCodec;
    private Surface encoderInputSurface;
    private Surface previewSurface;

    private HandlerThread cameraThread;
    private Handler cameraHandler;
    private Thread encoderThread;

    private volatile boolean isStreaming = false;
    private boolean useFrontCamera = false;
    private boolean isTorchOn = false;
    private int targetWidth = 1920;
    private int targetHeight = 1080;
    private CameraListener listener;

    private CameraStreamingHelper() {}

    public synchronized boolean isStreaming() {
        return isStreaming;
    }

    public synchronized boolean isFrontCamera() {
        return useFrontCamera;
    }

    public synchronized boolean isTorchOn() {
        return isTorchOn;
    }

    @SuppressLint("MissingPermission")
    public synchronized void startCamera(Context context,
                                        Surface localPreviewSurface,
                                        int width,
                                        int height,
                                        boolean frontCamera,
                                        CameraListener listener) {
        if (isStreaming) {
            Log.w(TAG, "摄像头已在运行中，请先停止再启动");
            return;
        }

        this.appContext = context.getApplicationContext();
        this.previewSurface = localPreviewSurface;
        this.targetWidth = (width > 0) ? width : 1920;
        this.targetHeight = (height > 0) ? height : 1080;
        this.useFrontCamera = frontCamera;
        this.listener = listener;

        startBackgroundThread();

        cameraManager = (CameraManager) appContext.getSystemService(Context.CAMERA_SERVICE);
        if (cameraManager == null) {
            if (listener != null) listener.onError("无法获取系统 CameraManager 服务");
            return;
        }

        try {
            String cameraId = chooseCameraId(useFrontCamera);
            if (cameraId == null) {
                if (listener != null) listener.onError("未找到可用的" + (useFrontCamera ? "前置" : "后置") + "摄像头");
                return;
            }

            // 初始化 MediaCodec H.264 硬件编码器
            initMediaCodec(targetWidth, targetHeight);

            // 打开摄像头设备
            cameraManager.openCamera(cameraId, new CameraDevice.StateCallback() {
                @Override
                public void onOpened(@NonNull CameraDevice camera) {
                    cameraDevice = camera;
                    createCameraCaptureSession();
                }

                @Override
                public void onDisconnected(@NonNull CameraDevice camera) {
                    Log.w(TAG, "摄像头已断开连接");
                    stopCamera();
                }

                @Override
                public void onError(@NonNull CameraDevice camera, int error) {
                    Log.e(TAG, "打开摄像头错误代码: " + error);
                    stopCamera();
                    if (listener != null) listener.onError("打开摄像头失败 (代码: " + error + ")");
                }
            }, cameraHandler);

        } catch (Throwable t) {
            Log.e(TAG, "启动摄像头异常: " + t.getMessage(), t);
            stopCamera();
            if (listener != null) listener.onError("启动摄像头异常: " + t.getMessage());
        }
    }

    private void initMediaCodec(int width, int height) throws IOException {
        MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_BIT_RATE, 4_500_000); // 4.5 Mbps 高画质
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 30);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1); // 每秒强制一个关键帧，秒开无延迟

        // 采用 Baseline Profile (零 B 帧重排等待延迟，最高实时性与播放器兼容性)
        try {
            format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline);
            format.setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel4);
        } catch (Throwable ignored) {}

        // CBR 固定码率模式，杜绝网络传输速率大幅抖动引发的缓冲延迟
        try {
            format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR);
        } catch (Throwable ignored) {}

        // Android 11+ (API 30+) 启用硬件编码器底层 0 延迟管道模式
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                format.setInteger(MediaFormat.KEY_LATENCY, 0);
                format.setInteger(MediaFormat.KEY_PRIORITY, 0); // 实时编码最高优先级
            } catch (Throwable ignored) {}
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 50_000); // 20fps 保活
        }

        videoCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        videoCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        encoderInputSurface = videoCodec.createInputSurface();
        videoCodec.start();

        isStreaming = true;
        startEncoderDrainThread();
    }

    private void createCameraCaptureSession() {
        if (cameraDevice == null || encoderInputSurface == null) return;

        try {
            List<Surface> outputSurfaces = new ArrayList<>();
            outputSurfaces.add(encoderInputSurface);
            if (previewSurface != null && previewSurface.isValid()) {
                outputSurfaces.add(previewSurface);
            }

            previewRequestBuilder = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
            previewRequestBuilder.addTarget(encoderInputSurface);
            if (previewSurface != null && previewSurface.isValid()) {
                previewRequestBuilder.addTarget(previewSurface);
            }

            // 自动对焦与曝光优化
            previewRequestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO);
            previewRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
            previewRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);

            cameraDevice.createCaptureSession(outputSurfaces, new CameraCaptureSession.StateCallback() {
                @Override
                public void onConfigured(@NonNull CameraCaptureSession session) {
                    captureSession = session;
                    try {
                        captureSession.setRepeatingRequest(previewRequestBuilder.build(), null, cameraHandler);
                        Log.i(TAG, "✓ 摄像头数据流成功绑定至硬件编码器 (" + targetWidth + "x" + targetHeight + ")");
                        if (listener != null) {
                            listener.onCameraStarted(targetWidth, targetHeight, useFrontCamera);
                        }
                    } catch (CameraAccessException e) {
                        Log.e(TAG, "设置重复拍照请求异常: " + e.getMessage(), e);
                    }
                }

                @Override
                public void onConfigureFailed(@NonNull CameraCaptureSession session) {
                    Log.e(TAG, "摄像头会话配置失败");
                    stopCamera();
                    if (listener != null) listener.onError("摄像头硬件会话配置失败");
                }
            }, cameraHandler);

        } catch (Throwable t) {
            Log.e(TAG, "创建 CameraCaptureSession 异常: " + t.getMessage(), t);
        }
    }

    private void startEncoderDrainThread() {
        encoderThread = new Thread(() -> {
            MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();
            byte[] cachedSpsPps = null;

            while (isStreaming && videoCodec != null) {
                try {
                    int outputBufferIndex = videoCodec.dequeueOutputBuffer(bufferInfo, 10000);
                    if (outputBufferIndex >= 0) {
                        ByteBuffer outputBuffer = videoCodec.getOutputBuffer(outputBufferIndex);
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            outputBuffer.position(bufferInfo.offset);
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size);

                            byte[] outData = new byte[bufferInfo.size];
                            outputBuffer.get(outData);

                            boolean isConfig = (bufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
                            boolean isKeyFrame = (bufferInfo.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;

                            if (isConfig) {
                                cachedSpsPps = outData;
                                FastMirrorSender.getInstance().setCameraSpsPps(cachedSpsPps);
                                LocalHttpTsServer.getInstance().getCameraChannel().setSpsPps(cachedSpsPps);
                            } else {
                                byte[] payloadToSend = outData;
                                if (isKeyFrame && cachedSpsPps != null && !containsSps(outData)) {
                                    byte[] combined = new byte[cachedSpsPps.length + outData.length];
                                    System.arraycopy(cachedSpsPps, 0, combined, 0, cachedSpsPps.length);
                                    System.arraycopy(outData, 0, combined, cachedSpsPps.length, outData.length);
                                    payloadToSend = combined;
                                }

                                // 通过 FastMirror MSG_CAMERA_FRAME 独立通道发送至 Mac 控制端
                                FastMirrorSender.getInstance().sendCamera(payloadToSend, isKeyFrame, bufferInfo.presentationTimeUs);
                                // 同步分发至局域网 TS 摄像头专属通道，彻底与屏幕投屏物理隔离
                                LocalHttpTsServer.getInstance().getCameraChannel().pushVideo(payloadToSend, isKeyFrame, bufferInfo.presentationTimeUs);
                            }
                        }
                        videoCodec.releaseOutputBuffer(outputBufferIndex, false);
                    } else if (outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        MediaFormat newFormat = videoCodec.getOutputFormat();
                        ByteBuffer sps = newFormat.getByteBuffer("csd-0");
                        ByteBuffer pps = newFormat.getByteBuffer("csd-1");
                        if (sps != null && pps != null) {
                            byte[] spsData = new byte[sps.remaining()];
                            sps.get(spsData);
                            byte[] ppsData = new byte[pps.remaining()];
                            pps.get(ppsData);
                            byte[] spsPps = new byte[spsData.length + ppsData.length];
                            System.arraycopy(spsData, 0, spsPps, 0, spsData.length);
                            System.arraycopy(ppsData, 0, spsPps, spsData.length, ppsData.length);
                            cachedSpsPps = spsPps;
                            FastMirrorSender.getInstance().setCameraSpsPps(cachedSpsPps);
                            LocalHttpTsServer.getInstance().getCameraChannel().setSpsPps(cachedSpsPps);
                        }
                    }
                } catch (Throwable t) {
                    if (isStreaming) {
                        Log.w(TAG, "读取摄像头编码帧异常: " + t.getMessage());
                    }
                }
            }
        }, "CameraEncoderDrain");
        encoderThread.start();
    }

    private boolean containsSps(byte[] data) {
        if (data == null || data.length < 5) return false;
        for (int i = 0; i < data.length - 4; i++) {
            if (data[i] == 0 && data[i + 1] == 0 && ((data[i + 2] == 1 && (data[i + 3] & 0x1F) == 7) ||
                    (data[i + 2] == 0 && data[i + 3] == 1 && (data[i + 4] & 0x1F) == 7))) {
                return true;
            }
        }
        return false;
    }

    public synchronized void switchCamera() {
        if (!isStreaming) return;
        boolean newFacing = !useFrontCamera;
        Context ctx = this.appContext;
        Surface surf = this.previewSurface;
        int w = this.targetWidth;
        int h = this.targetHeight;
        CameraListener lis = this.listener;

        stopCamera();
        startCamera(ctx, surf, w, h, newFacing, lis);
    }

    public synchronized void toggleTorch() {
        if (!isStreaming || previewRequestBuilder == null || captureSession == null) return;
        if (useFrontCamera) {
            Log.i(TAG, "前置摄像头不支持补光灯");
            return;
        }

        try {
            isTorchOn = !isTorchOn;
            previewRequestBuilder.set(CaptureRequest.FLASH_MODE,
                    isTorchOn ? CaptureRequest.FLASH_MODE_TORCH : CaptureRequest.FLASH_MODE_OFF);
            captureSession.setRepeatingRequest(previewRequestBuilder.build(), null, cameraHandler);
            Log.i(TAG, "补光灯已" + (isTorchOn ? "开启" : "关闭"));
        } catch (Throwable t) {
            Log.e(TAG, "切换补光灯异常: " + t.getMessage());
        }
    }

    public static void requestKeyFrame() {
        CameraStreamingHelper helper = INSTANCE;
        if (helper.isStreaming && helper.videoCodec != null) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                    Bundle params = new Bundle();
                    params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
                    helper.videoCodec.setParameters(params);
                }
            } catch (Throwable ignored) {}
        }
    }

    public synchronized void stopCamera() {
        isStreaming = false;
        isTorchOn = false;

        if (captureSession != null) {
            try {
                captureSession.stopRepeating();
                captureSession.close();
            } catch (Throwable ignored) {}
            captureSession = null;
        }

        if (cameraDevice != null) {
            try {
                cameraDevice.close();
            } catch (Throwable ignored) {}
            cameraDevice = null;
        }

        if (videoCodec != null) {
            try {
                videoCodec.stop();
                videoCodec.release();
            } catch (Throwable ignored) {}
            videoCodec = null;
        }

        if (encoderInputSurface != null) {
            try {
                encoderInputSurface.release();
            } catch (Throwable ignored) {}
            encoderInputSurface = null;
        }

        stopBackgroundThread();

        LocalHttpTsServer.getInstance().getCameraChannel().reset();

        if (listener != null) {
            listener.onCameraStopped();
        }
        Log.i(TAG, "已安全关闭 Android 摄像头并释放硬件资源");
    }

    private String chooseCameraId(boolean front) throws CameraAccessException {
        int targetFacing = front ? CameraCharacteristics.LENS_FACING_FRONT : CameraCharacteristics.LENS_FACING_BACK;
        for (String id : cameraManager.getCameraIdList()) {
            CameraCharacteristics c = cameraManager.getCameraCharacteristics(id);
            Integer facing = c.get(CameraCharacteristics.LENS_FACING);
            if (facing != null && facing == targetFacing) {
                return id;
            }
        }
        // 回退选择首个可用摄像头
        String[] ids = cameraManager.getCameraIdList();
        return (ids != null && ids.length > 0) ? ids[0] : null;
    }

    private void startBackgroundThread() {
        if (cameraThread == null) {
            cameraThread = new HandlerThread("CameraBackgroundThread");
            cameraThread.start();
            cameraHandler = new Handler(cameraThread.getLooper());
        }
    }

    private void stopBackgroundThread() {
        if (cameraThread != null) {
            cameraThread.quitSafely();
            try {
                cameraThread.join(500);
            } catch (Throwable ignored) {}
            cameraThread = null;
            cameraHandler = null;
        }
    }
}

