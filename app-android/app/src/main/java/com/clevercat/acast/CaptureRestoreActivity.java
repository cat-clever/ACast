package com.clevercat.acast;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.WindowManager;

/**
 * 屏幕投屏极速恢复透明 Activity (解决 Android 14+ 锁屏解锁后录屏权限被系统切断的恢复问题)
 */
public class CaptureRestoreActivity extends Activity {

    private static final String TAG = "CaptureRestoreActivity";
    private static final int REQUEST_CODE_RESTORE = 9999;

    public static void start(Context context) {
        if (context == null) return;
        try {
            Intent intent = new Intent(context, CaptureRestoreActivity.class);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
            context.startActivity(intent);
        } catch (Throwable t) {
            Log.e(TAG, "启动 CaptureRestoreActivity 异常: " + t.getMessage(), t);
        }
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL);

        MediaProjectionManager manager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
        if (manager != null) {
            try {
                Intent captureIntent;
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    android.media.projection.MediaProjectionConfig config =
                            android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay();
                    captureIntent = manager.createScreenCaptureIntent(config);
                } else {
                    captureIntent = manager.createScreenCaptureIntent();
                }
                ScreenCaptureService.notifyAwaitingRestore(true);
                startActivityForResult(captureIntent, REQUEST_CODE_RESTORE);
            } catch (Throwable t) {
                Log.e(TAG, "调起录屏恢复弹窗异常: " + t.getMessage(), t);
                ScreenCaptureService.notifyAwaitingRestore(false);
                finish();
            }
        } else {
            finish();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        ScreenCaptureService.notifyAwaitingRestore(false);
        if (requestCode == REQUEST_CODE_RESTORE) {
            if (resultCode == RESULT_OK && data != null) {
                Log.i(TAG, "✓ 用户/无障碍已确认投屏恢复，正在重新激活管线...");
                ScreenCaptureService.restartProjectionWithConsent(this, resultCode, data);
            } else {
                Log.w(TAG, "恢复投屏授权未被确认");
            }
        }
        finish();
    }
}

