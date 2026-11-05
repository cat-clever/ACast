package com.clevercat.acast;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

public class ControlAccessibilityService extends AccessibilityService {

    private static final String TAG = "ControlAccessibilityService";
    private static ControlAccessibilityService instance;
    private static final Handler sMainHandler = new Handler(Looper.getMainLooper());

    // 常亮 Overlay 窗口 View
    private View keepScreenOnOverlayView;

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
        Log.i(TAG, "✓ 无障碍反控服务已就绪连接！");
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {}

    @Override
    public void onInterrupt() {}

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        setKeepScreenOnInternal(false);
        instance = null;
        isPointerDown = false;
        return super.onUnbind(intent);
    }

    @Override
    public void onDestroy() {
        setKeepScreenOnInternal(false);
        instance = null;
        isPointerDown = false;
        super.onDestroy();
    }

    public static boolean isAvailable() {
        return instance != null;
    }

    /**
     * 收到反控指令但无障碍服务未就绪时向手机端屏幕展示引导 Toast
     */
    public static void showAccessibilityTipToast(Context context) {
        if (context == null) return;
        sMainHandler.post(() -> {
            try {
                android.widget.Toast.makeText(context.getApplicationContext(),
                        "💡 ACast 提示：请在手机【系统设置 - 无障碍】中开启【ACast 投屏反控】，以允许电脑控制手机",
                        android.widget.Toast.LENGTH_LONG).show();
            } catch (Throwable ignored) {}
        });
    }

    /**
     * 检查系统设置中 ACast 无障碍服务是否已开启
     */
    public static boolean isAccessibilitySettingsOn(Context context) {
        if (context == null) return false;
        if (instance != null) return true;

        int accessibilityEnabled = 0;
        final String serviceName = context.getPackageName() + "/" + ControlAccessibilityService.class.getName();
        try {
            accessibilityEnabled = Settings.Secure.getInt(
                    context.getApplicationContext().getContentResolver(),
                    Settings.Secure.ACCESSIBILITY_ENABLED
            );
        } catch (Settings.SettingNotFoundException ignored) {}

        TextUtils.SimpleStringSplitter colonSplitter = new TextUtils.SimpleStringSplitter(':');
        if (accessibilityEnabled == 1) {
            String settingValue = Settings.Secure.getString(
                    context.getApplicationContext().getContentResolver(),
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            );
            if (settingValue != null) {
                colonSplitter.setString(settingValue);
                while (colonSplitter.hasNext()) {
                    String componentName = colonSplitter.next();
                    if (componentName.equalsIgnoreCase(serviceName)) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /**
     * 投屏期间设置屏幕全局常亮，避免自动超时锁屏
     */
    public static void setKeepScreenOn(boolean enable) {
        if (instance != null) {
            sMainHandler.post(() -> instance.setKeepScreenOnInternal(enable));
        }
    }

    private void setKeepScreenOnInternal(boolean enable) {
        try {
            WindowManager wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
            if (wm == null) return;

            if (enable) {
                if (keepScreenOnOverlayView == null) {
                    keepScreenOnOverlayView = new View(this);
                    int overlayType = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ?
                            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY :
                            WindowManager.LayoutParams.TYPE_SYSTEM_OVERLAY;

                    WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                            1, 1,
                            overlayType,
                            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE |
                            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE |
                            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                            PixelFormat.TRANSLUCENT
                    );
                    params.gravity = Gravity.START | Gravity.TOP;
                    params.x = 0;
                    params.y = 0;
                    wm.addView(keepScreenOnOverlayView, params);
                    Log.i(TAG, "✓ 投屏屏幕常亮保护已激活 (Accessibility Overlay)");
                }
            } else {
                if (keepScreenOnOverlayView != null) {
                    wm.removeView(keepScreenOnOverlayView);
                    keepScreenOnOverlayView = null;
                    Log.i(TAG, "投屏屏幕常亮保护已解除");
                }
            }
        } catch (Throwable t) {
            Log.w(TAG, "setKeepScreenOnInternal 异常: " + t.getMessage());
        }
    }

    /**
     * 唤醒屏幕（若屏幕处于息屏非活动状态）
     */
    private static void wakeUpScreenIfNeeded() {
        if (instance == null) return;
        try {
            PowerManager pm = (PowerManager) instance.getSystemService(Context.POWER_SERVICE);
            if (pm != null && !pm.isInteractive()) {
                PowerManager.WakeLock wakeLock = pm.newWakeLock(
                        PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP,
                        "acast:wake_on_click"
                );
                wakeLock.acquire(1000);
            }
        } catch (Throwable t) {
            Log.w(TAG, "唤醒屏幕异常: " + t.getMessage());
        }
    }

    /**
     * 获取真实物理屏幕尺寸
     */
    private static DisplayMetrics getRealScreenMetrics() {
        DisplayMetrics metrics = new DisplayMetrics();
        if (instance == null) return metrics;
        try {
            WindowManager wm = (WindowManager) instance.getSystemService(Context.WINDOW_SERVICE);
            if (wm != null && wm.getDefaultDisplay() != null) {
                wm.getDefaultDisplay().getRealMetrics(metrics);
                return metrics;
            }
        } catch (Throwable ignored) {}
        return instance.getResources().getDisplayMetrics();
    }

    /**
     * 响应电脑端鼠标点击与拖拽滑动模拟触控
     * @param action 0x10: DOWN, 0x11: MOVE, 0x12: UP
     * @param normX 归一化 X (0 ~ 10000)
     * @param normY 归一化 Y (0 ~ 10000)
     */
    public static void injectTouch(byte action, int normX, int normY) {
        if (instance == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return;

        DisplayMetrics dm = getRealScreenMetrics();
        float screenW = dm.widthPixels > 0 ? dm.widthPixels : 1080;
        float screenH = dm.heightPixels > 0 ? dm.heightPixels : 1920;

        float currentX = (normX / 10000.0f) * screenW;
        float currentY = (normY / 10000.0f) * screenH;

        if (action == 0x10) { // TOUCH_DOWN
            isPointerDown = true;
            downNormX = currentX;
            downNormY = currentY;
            lastNormX = currentX;
            lastNormY = currentY;
            downTimeMs = System.currentTimeMillis();
            wakeUpScreenIfNeeded();
        } else if (action == 0x11) { // TOUCH_MOVE
            if (isPointerDown) {
                lastNormX = currentX;
                lastNormY = currentY;
            }
        } else if (action == 0x12) { // TOUCH_UP
            if (!isPointerDown) return;
            isPointerDown = false;
            long duration = System.currentTimeMillis() - downTimeMs;

            float startX = downNormX;
            float startY = downNormY;
            float endX = lastNormX;
            float endY = lastNormY;

            float dx = endX - startX;
            float dy = endY - startY;
            double dist = Math.hypot(dx, dy);

            sMainHandler.post(() -> {
                if (instance == null) return;
                try {
                    Path path = new Path();
                    path.moveTo(startX, startY);

                    long strokeDur;
                    if (dist < 20.0) {
                        // 点按操作：必须增加微小偏移 (+1.0f)，确保 Path 长度非零，避免系统抛出 Empty Path 异常
                        path.lineTo(startX + 1.0f, startY + 1.0f);
                        strokeDur = Math.max(50, Math.min(duration, 300));
                    } else {
                        // 滑动/拖拽手势
                        path.lineTo(endX, endY);
                        strokeDur = Math.max(100, Math.min(duration, 400));
                    }

                    GestureDescription.Builder builder = new GestureDescription.Builder();
                    builder.addStroke(new GestureDescription.StrokeDescription(path, 0, strokeDur));
                    instance.dispatchGesture(builder.build(), new GestureResultCallback() {
                        @Override
                        public void onCompleted(GestureDescription gestureDescription) {
                            super.onCompleted(gestureDescription);
                        }

                        @Override
                        public void onCancelled(GestureDescription gestureDescription) {
                            super.onCancelled(gestureDescription);
                            Log.w(TAG, "手势模拟被系统取消");
                        }
                    }, null);
                } catch (Throwable t) {
                    Log.e(TAG, "dispatchGesture 执行异常: " + t.getMessage(), t);
                }
            });
        }
    }

    /**
     * 电脑键盘文本输入上屏：优先剪贴板在光标处插入粘贴，备用模式下获取已有文本拼接追加，杜绝整框单字覆盖
     */
    public static void injectText(String text) {
        if (instance == null || text == null || text.isEmpty()) return;

        sMainHandler.post(() -> {
            try {
                wakeUpScreenIfNeeded();
                AccessibilityNodeInfo root = instance.getRootInActiveWindow();
                if (root != null) {
                    AccessibilityNodeInfo focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                    if (focused != null) {
                        // 1. 优先尝试系统剪贴板光标处粘贴（最符合自然打字体验，支持光标位置插入）
                        ClipboardManager cm = (ClipboardManager) instance.getSystemService(Context.CLIPBOARD_SERVICE);
                        if (cm != null) {
                            ClipData clip = ClipData.newPlainText("ACast_Input", text);
                            cm.setPrimaryClip(clip);
                            if (focused.performAction(AccessibilityNodeInfo.ACTION_PASTE)) {
                                return;
                            }
                        }

                        // 2. 备用追加模式：读取已有文本并在末尾拼接，绝对不能直接覆盖整框文本！
                        CharSequence existing = focused.getText();
                        String newText = (existing != null ? existing.toString() : "") + text;
                        Bundle arguments = new Bundle();
                        arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText);
                        if (focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
                            return;
                        }
                    }
                }

                // 3. 兜底备用：剪贴板注入
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
        if (instance == null) {
            Log.w(TAG, "injectKey 失败: 无障碍服务未开启或尚未就绪！无法模拟按键 keyCode=" + keyCode);
            return;
        }
        sMainHandler.post(() -> {
            if (instance == null) return;
            wakeUpScreenIfNeeded();
            boolean handled = false;
            switch (keyCode) {
                case 1: // KEY_BACK
                    handled = instance.performGlobalAction(GLOBAL_ACTION_BACK);
                    break;
                case 2: // KEY_HOME
                    handled = instance.performGlobalAction(GLOBAL_ACTION_HOME);
                    break;
                case 3: // KEY_APP_SWITCH
                    handled = instance.performGlobalAction(GLOBAL_ACTION_RECENTS);
                    break;
                case 4: // KEY_POWER
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        handled = instance.performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN);
                    }
                    break;
                case 5: // KEY_NOTIFICATIONS
                    handled = instance.performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS);
                    break;
                case 6: // KEY_QUICK_SETTINGS
                    handled = instance.performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS);
                    break;
                case 7: // KEY_DEL (退格删除键)
                    AccessibilityNodeInfo root = instance.getRootInActiveWindow();
                    if (root != null) {
                        AccessibilityNodeInfo focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                        if (focused != null) {
                            CharSequence cur = focused.getText();
                            if (cur != null && cur.length() > 0) {
                                String delText = cur.subSequence(0, cur.length() - 1).toString();
                                Bundle args = new Bundle();
                                args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, delText);
                                handled = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
                            }
                        }
                    }
                    break;
                default:
                    Log.w(TAG, "未知的全局按键码: " + keyCode);
                    break;
            }
            Log.i(TAG, "执行全局按键映射: keyCode=" + keyCode + ", 成功=" + handled);
        });
    }
}
