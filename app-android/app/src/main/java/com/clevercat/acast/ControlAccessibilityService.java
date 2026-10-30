package com.clevercat.acast;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Path;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

public class ControlAccessibilityService extends AccessibilityService {

    private static final String TAG = "ControlAccessibilityService";
    private static ControlAccessibilityService instance;

    // 手势状态跟踪
    private static float downNormX = 0f;
    private static float downNormY = 0f;
    private static long downTimeMs = 0L;
    private static float lastNormX = 0f;
    private static float lastNormY = 0f;
    private static boolean isPointerDown = false;

    @Override
    public void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
        Log.i(TAG, "无障碍反控服务已就绪连接！");
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {}

    @Override
    public void onInterrupt() {}

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        instance = null;
        isPointerDown = false;
        return super.onUnbind(intent);
    }

    public static boolean isAvailable() {
        return instance != null;
    }

    /**
     * 响应电脑端鼠标点击与拖拽滑动模拟触控
     * @param action 0x10: DOWN, 0x11: MOVE, 0x12: UP
     * @param normX 归一化 X (0 ~ 10000)
     * @param normY 归一化 Y (0 ~ 10000)
     */
    public static void injectTouch(byte action, int normX, int normY) {
        if (instance == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return;

        DisplayMetrics dm = instance.getResources().getDisplayMetrics();
        float currentX = (normX / 10000.0f) * dm.widthPixels;
        float currentY = (normY / 10000.0f) * dm.heightPixels;

        if (action == 0x10) { // TOUCH_DOWN
            isPointerDown = true;
            downNormX = currentX;
            downNormY = currentY;
            lastNormX = currentX;
            lastNormY = currentY;
            downTimeMs = System.currentTimeMillis();
        } else if (action == 0x11) { // TOUCH_MOVE
            if (isPointerDown) {
                lastNormX = currentX;
                lastNormY = currentY;
            }
        } else if (action == 0x12) { // TOUCH_UP
            if (!isPointerDown) return;
            isPointerDown = false;
            long duration = System.currentTimeMillis() - downTimeMs;

            float dx = lastNormX - downNormX;
            float dy = lastNormY - downNormY;
            double dist = Math.hypot(dx, dy);

            Path path = new Path();
            path.moveTo(downNormX, downNormY);

            if (dist < 20.0) {
                // 点击或长按
                long strokeDur = Math.max(50, Math.min(duration, 800));
                path.lineTo(downNormX, downNormY);
                GestureDescription.Builder builder = new GestureDescription.Builder();
                builder.addStroke(new GestureDescription.StrokeDescription(path, 0, strokeDur));
                instance.dispatchGesture(builder.build(), null, null);
            } else {
                // 顺滑滑动手势 (Swipe / Drag)
                path.lineTo(lastNormX, lastNormY);
                long swipeDur = Math.max(100, Math.min(duration, 350));
                GestureDescription.Builder builder = new GestureDescription.Builder();
                builder.addStroke(new GestureDescription.StrokeDescription(path, 0, swipeDur));
                instance.dispatchGesture(builder.build(), null, null);
            }
        }
    }

    /**
     * 电脑键盘文本输入上屏：优先尝试无障碍直接填入，若无焦点则通过剪贴板粘贴
     */
    public static void injectText(String text) {
        if (instance == null || text == null || text.isEmpty()) return;

        new Handler(Looper.getMainLooper()).post(() -> {
            try {
                AccessibilityNodeInfo root = instance.getRootInActiveWindow();
                if (root != null) {
                    AccessibilityNodeInfo focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                    if (focused != null) {
                        Bundle arguments = new Bundle();
                        arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text);
                        if (focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
                            return;
                        }
                    }
                }

                // 备用机制：复制至剪贴板
                ClipboardManager cm = (ClipboardManager) instance.getSystemService(Context.CLIPBOARD_SERVICE);
                if (cm != null) {
                    ClipData clip = ClipData.newPlainText("ACast_Input", text);
                    cm.setPrimaryClip(clip);
                }
            } catch (Throwable t) {
                Log.w(TAG, "文本注入异常: " + t.getMessage());
            }
        });
    }

    /**
     * 电脑按键映射：物理键与全局功能键
     */
    public static void injectKey(int keyCode) {
        if (instance == null) return;
        switch (keyCode) {
            case 1: // KEY_BACK
                instance.performGlobalAction(GLOBAL_ACTION_BACK);
                break;
            case 2: // KEY_HOME
                instance.performGlobalAction(GLOBAL_ACTION_HOME);
                break;
            case 3: // KEY_APP_SWITCH
                instance.performGlobalAction(GLOBAL_ACTION_RECENTS);
                break;
            case 4: // KEY_POWER
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    instance.performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN);
                }
                break;
            case 5: // KEY_NOTIFICATIONS
                instance.performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS);
                break;
            case 6: // KEY_QUICK_SETTINGS
                instance.performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS);
                break;
        }
    }
}


