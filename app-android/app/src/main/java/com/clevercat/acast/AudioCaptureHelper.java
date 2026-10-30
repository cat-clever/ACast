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
        int minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT);

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
            } catch (Exception e) {
                Log.w(TAG, "启用内录失败，降级为麦克风外录: " + e.getMessage());
                audioRecord = new AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, minBufferSize);
            }
        } else {
            // Android 7.0 ~ 9.0 兼容方案：麦克风环境外录
            audioRecord = new AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, minBufferSize);
            Log.i(TAG, "已启用 Android 7~9 兼容方案 (麦克风音频采集)");
        }

        if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord 初始化失败");
            return;
        }

        audioRecord.startRecording();
        isRecording = true;

        recordThread = new Thread(() -> {
            byte[] buffer = new byte[2048];
            while (isRecording) {
                int read = audioRecord.read(buffer, 0, buffer.length);
                if (read > 0 && callback != null) {
                    callback.onAudioData(buffer, read);
                }
            }
        });
        recordThread.start();
    }

    public void stopCapture() {
        isRecording = false;
        if (recordThread != null) {
            try {
                recordThread.join(500);
            } catch (InterruptedException ignored) {}
        }
        if (audioRecord != null) {
            try {
                audioRecord.stop();
                audioRecord.release();
            } catch (Exception ignored) {}
            audioRecord = null;
        }
    }
}

