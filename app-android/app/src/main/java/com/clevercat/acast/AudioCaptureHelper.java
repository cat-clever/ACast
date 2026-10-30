package com.clevercat.acast;

import android.annotation.SuppressLint;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.util.Log;

public class AudioCaptureHelper {

    private static final String TAG = "AudioCaptureHelper";
    private static final int SAMPLE_RATE = 44100;
    private static final int CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO;
    private static final int AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT;

    public interface AudioDataCallback {
        void onAudioData(byte[] buffer, int size);
    }

    private AudioRecord audioRecord;
    private boolean isRecording = false;
    private Thread recordThread;

    @SuppressLint("MissingPermission")
    public void startCapture(MediaProjection mediaProjection, AudioDataCallback callback) {
        try {
            int minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT);
            if (minBufferSize <= 0) minBufferSize = 4096;

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && mediaProjection != null) {
                // Android 10+ 官方系统内录 API (AudioPlaybackCapture)
                try {
                    AudioPlaybackCaptureConfiguration config = new AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                            .addMatchingUsage(AudioAttributes.USAGE_GAME)
                            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                            .build();

                    AudioFormat format = new AudioFormat.Builder()
                            .setEncoding(AUDIO_FORMAT)
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelMask(CHANNEL_CONFIG)
                            .build();

                    audioRecord = new AudioRecord.Builder()
                            .setAudioFormat(format)
                            .setBufferSizeInBytes(Math.max(minBufferSize, 4096))
                            .setAudioPlaybackCaptureConfig(config)
                            .build();
                    Log.i(TAG, "已启用 Android 10+ 原生 AudioPlaybackCapture 系统纯净内录");
                } catch (Throwable e) {
                    Log.w(TAG, "启用系统内录失败，尝试降级为麦克风外录: " + e.getMessage());
                    try {
                        audioRecord = new AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, minBufferSize);
                    } catch (Throwable ignored) {
                        audioRecord = null;
                    }
                }
            } else {
                // Android 7.0 ~ 9.0 兼容方案：麦克风环境外录
                try {
                    audioRecord = new AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, minBufferSize);
                    Log.i(TAG, "已启用 Android 7~9 兼容方案 (麦克风音频采集)");
                } catch (Throwable e) {
                    Log.w(TAG, "初始化麦克风音频录制失败: " + e.getMessage());
                    audioRecord = null;
                }
            }

            if (audioRecord == null || audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                Log.w(TAG, "AudioRecord 未就绪，本次将以纯视频画面投屏运行");
                return;
            }

            audioRecord.startRecording();
            isRecording = true;

            recordThread = new Thread(() -> {
                byte[] buffer = new byte[2048];
                while (isRecording) {
                    try {
                        if (audioRecord == null) break;
                        int read = audioRecord.read(buffer, 0, buffer.length);
                        if (read > 0 && callback != null) {
                            callback.onAudioData(buffer, read);
                        }
                    } catch (Throwable t) {
                        Log.w(TAG, "音频流读取异常: " + t.getMessage());
                        break;
                    }
                }
            }, "ACastAudioRecordThread");
            recordThread.start();

        } catch (Throwable t) {
            Log.w(TAG, "startCapture 捕获异常，已降级静音保护: " + t.getMessage());
        }
    }

    public void stopCapture() {
        isRecording = false;
        if (recordThread != null) {
            try {
                recordThread.join(300);
            } catch (Throwable ignored) {}
        }
        if (audioRecord != null) {
            try {
                audioRecord.stop();
                audioRecord.release();
            } catch (Throwable ignored) {}
            audioRecord = null;
        }
    }
}
