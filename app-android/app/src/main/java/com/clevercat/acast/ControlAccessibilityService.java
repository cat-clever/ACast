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
import android.view.accessibility.AccessibilityWindowInfo;

public class ControlAccessibilityService extends AccessibilityService {

    private static final String TAG = "ControlAccessibilityService";
    private static ControlAccessibilityService instance;
    private static final Handler sMainHandler = new Handler(Looper.getMainLooper());

    // 常亮 Overlay 窗口 View
    private View keepScreenOnOverlayView;

    // 连续手势引擎状态机 (支持真正持续不松手跟手滑动与高速甩动翻页)
    private static volatile boolean isPointerDown = false;
    private static float downX = 0f;
    private static float downY = 0f;
    private static long downTimeMs = 0L;
    private static float currentTargetX = 0f;
    private static float currentTargetY = 0f;
    private static float lastStrokeEndX = 0f;
    private static float lastStrokeEndY = 0f;
    private static boolean isDispatching = false;
    private static boolean pendingFinalUp = false;
    private static GestureDescription.StrokeDescription currentStroke = null;
    private static boolean hasMoved = false;

    // 触控防死锁看门狗：防止鼠标移出视窗或极端丢包导致手指在系统底层永远按住
    private static final Runnable sWatchdogRunnable = () -> {
        if (isPointerDown) {
            Log.w(TAG, "⚠️ 触控安全看门狗超时触发，强制执行安全抬手！");
            isPointerDown = false;
            pendingFinalUp = false;
            currentStroke = null;
            isDispatching = false;
        }
    };

    @Override
    public void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
        Log.i(TAG, "✓ 无障碍反控服务已就绪连接！");
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null) return;

        // 若处于锁屏唤醒重连等待阶段，自动辅助点击系统投屏授权弹窗中的“立即开始”或“允许”
        if (ScreenCaptureService.isAwaitingRestore()) {
            tryAutoConfirmMediaProjection();
        }
    }

    private void tryAutoConfirmMediaProjection() {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return;
        try {
            findAndClickConfirmButton(root);
        } finally {
            root.recycle();
        }
    }

    private boolean findAndClickConfirmButton(AccessibilityNodeInfo node) {
        if (node == null) return false;
        CharSequence text = node.getText();
        CharSequence desc = node.getContentDescription();
        String str = (text != null ? text.toString() : "") + (desc != null ? desc.toString() : "");

        if (!str.isEmpty() && (str.contains("立即开始") || str.contains("允许") || str.contains("Start now") || str.contains("Start Now") || str.contains("立即开启"))) {
            if (node.isClickable()) {
                boolean clicked = node.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                Log.i(TAG, "✓ 无障碍服务已自动确认系统投屏授权: " + str + ", result=" + clicked);
                return true;
            }
            AccessibilityNodeInfo parent = node.getParent();
            while (parent != null) {
                if (parent.isClickable()) {
                    boolean clicked = parent.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                    Log.i(TAG, "✓ 无障碍服务已点击父级授权按钮: " + str + ", result=" + clicked);
                    parent.recycle();
                    return true;
                }
                AccessibilityNodeInfo temp = parent.getParent();
                parent.recycle();
                parent = temp;
            }
        }

        int childCount = node.getChildCount();
        for (int i = 0; i < childCount; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) {
                boolean found = findAndClickConfirmButton(child);
                child.recycle();
                if (found) return true;
            }
        }
        return false;
    }

    /**
     * 当检测到电脑反控活跃事件时，重置系统息屏计时器
     */
    public static void onUserActivityDetected() {
        if (instance == null) return;
        try {
            wakeUpScreenIfNeeded();
        } catch (Throwable ignored) {}
    }

    @Override
    public void onInterrupt() {}

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        setKeepScreenOnInternal(false);
        instance = null;
        isPointerDown = false;
        isDispatching = false;
        currentStroke = null;
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
                Log.i(TAG, "已触发屏幕点亮唤醒，通知重新激活 VirtualDisplay");
                ScreenCaptureService.onScreenUnlocked();
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
     * 连续手势泵动循环：通过 willContinue = true / continueStroke 保持手指贴在屏幕上不抬起，
     * 随着鼠标光标移动实时平滑滚动屏幕；当松手时通过 willContinue = false 安全抬起。
     */
    private static synchronized void pumpContinuousGesture() {
        if (instance == null || isDispatching || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return;

        float targetX = currentTargetX;
        float targetY = currentTargetY;
        float startX = (currentStroke == null) ? downX : lastStrokeEndX;
        float startY = (currentStroke == null) ? downY : lastStrokeEndY;

        float dx = targetX - startX;
        float dy = targetY - startY;
        double dist = Math.hypot(dx, dy);

        // 如果位移微小且手指仍在按下中，等待稍大位移以合并高频更新
        if (dist < 4.0f && isPointerDown && currentStroke != null) {
            return;
        }

        isDispatching = true;
        sMainHandler.post(() -> {
            if (instance == null) {
                isDispatching = false;
                currentStroke = null;
                pendingFinalUp = false;
                return;
            }

            try {
                GestureDescription.Builder builder = new GestureDescription.Builder();
                GestureDescription.StrokeDescription stroke;

                Path path = new Path();
                path.moveTo(startX, startY);
                if (dist < 1.0f) {
                    path.lineTo(startX + 1.0f, startY + 1.0f);
                } else {
                    path.lineTo(targetX, targetY);
                }

                lastStrokeEndX = targetX;
                lastStrokeEndY = targetY;

                boolean willContinue = isPointerDown;
                float finalTargetX = targetX;
                float finalTargetY = targetY;
                long dur = Math.max(30L, Math.min(75L, (long)(dist * 0.75)));

                if (!willContinue) {
                    // 抬手收尾：检测是否属于快速甩动 (Fling/Swipe 翻页)
                    float totalDx = currentTargetX - downX;
                    float totalDy = currentTargetY - downY;
                    long totalDur = System.currentTimeMillis() - downTimeMs;
                    if ((Math.abs(totalDx) > 35.0f || Math.abs(totalDy) > 35.0f) && totalDur < 650L) {
                        DisplayMetrics dm = getRealScreenMetrics();
                        float screenW = dm.widthPixels > 0 ? dm.widthPixels : 1080;
                        float screenH = dm.heightPixels > 0 ? dm.heightPixels : 1920;
                        if (Math.abs(totalDx) >= Math.abs(totalDy)) {
                            finalTargetX += (totalDx > 0 ? 120.0f : -120.0f);
                            finalTargetX = Math.max(0.0f, Math.min(screenW, finalTargetX));
                        } else {
                            finalTargetY += (totalDy > 0 ? 120.0f : -120.0f);
                            finalTargetY = Math.max(0.0f, Math.min(screenH, finalTargetY));
                        }
                        dur = 40L; // 以极短时间完成位移，赋予 Android 桌面系统强劲的翻页初速度
                    }
                }

                if (dist >= 1.0f || !willContinue) {
                    path.lineTo(finalTargetX, finalTargetY);
                }

                lastStrokeEndX = finalTargetX;
                lastStrokeEndY = finalTargetY;

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && currentStroke != null) {
                    stroke = currentStroke.continueStroke(path, 0, dur, willContinue);
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    stroke = new GestureDescription.StrokeDescription(path, 0, dur, willContinue);
                } else {
                    stroke = new GestureDescription.StrokeDescription(path, 0, dur);
                }
                currentStroke = willContinue ? stroke : null;
                builder.addStroke(stroke);

                instance.dispatchGesture(builder.build(), new GestureResultCallback() {
                    @Override
                    public void onCompleted(GestureDescription gestureDescription) {
                        super.onCompleted(gestureDescription);
                        isDispatching = false;
                        if (isPointerDown) {
                            pumpContinuousGesture();
                        } else if (pendingFinalUp || currentStroke != null) {
                            pendingFinalUp = false;
                            pumpContinuousGesture();
                        }
                    }

                    @Override
                    public void onCancelled(GestureDescription gestureDescription) {
                        super.onCancelled(gestureDescription);
                        isDispatching = false;
                        currentStroke = null;
                        pendingFinalUp = false;
                        if (isPointerDown) {
                            pumpContinuousGesture();
                        }
                    }
                }, null);

            } catch (Throwable t) {
                Log.w(TAG, "连续手势派发异常: " + t.getMessage());
                isDispatching = false;
                currentStroke = null;
                pendingFinalUp = false;
            }
        });
    }

    /**
     * 响应电脑端鼠标点击与拖拽滑动模拟触控（支持真正连续不松手跟手滑动与高速甩动翻页）
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
            hasMoved = false;
            pendingFinalUp = false;
            downX = currentX;
            downY = currentY;
            currentTargetX = currentX;
            currentTargetY = currentY;
            lastStrokeEndX = currentX;
            lastStrokeEndY = currentY;
            downTimeMs = System.currentTimeMillis();
            currentStroke = null;
            isDispatching = false;
            wakeUpScreenIfNeeded();

            // 超时防死锁看门狗：如果按下超过 2.5 秒未收到抬起且无位移，强制安全抬起
            sMainHandler.removeCallbacks(sWatchdogRunnable);
            sMainHandler.postDelayed(sWatchdogRunnable, 2500);

        } else if (action == 0x11) { // TOUCH_MOVE
            if (!isPointerDown) return;
            currentTargetX = currentX;
            currentTargetY = currentY;

            float totalDx = currentX - downX;
            float totalDy = currentY - downY;
            if (Math.hypot(totalDx, totalDy) > 10.0f) {
                hasMoved = true;
            }

            // 重置看门狗
            sMainHandler.removeCallbacks(sWatchdogRunnable);
            sMainHandler.postDelayed(sWatchdogRunnable, 2500);

            if (hasMoved && !isDispatching) {
                pumpContinuousGesture();
            }

        } else if (action == 0x12) { // TOUCH_UP
            sMainHandler.removeCallbacks(sWatchdogRunnable);
            if (!isPointerDown) return;
            isPointerDown = false;
            long duration = System.currentTimeMillis() - downTimeMs;
            currentTargetX = currentX;
            currentTargetY = currentY;

            float totalDx = currentX - downX;
            float totalDy = currentY - downY;

            if (!hasMoved) {
                // 纯点击 (Tap) 操作
                sMainHandler.post(() -> {
                    if (instance == null) return;
                    try {
                        Path clickPath = new Path();
                        clickPath.moveTo(downX, downY);
                        clickPath.lineTo(downX + 1.0f, downY + 1.0f);
                        GestureDescription.Builder b = new GestureDescription.Builder();
                        b.addStroke(new GestureDescription.StrokeDescription(clickPath, 0, Math.max(30L, Math.min(duration, 120L))));
                        instance.dispatchGesture(b.build(), null, null);
                    } catch (Throwable t) {
                        Log.w(TAG, "单击异常: " + t.getMessage());
                    }
                });
                currentStroke = null;
                isDispatching = false;
                pendingFinalUp = false;

            } else {
                // 滑动手势：
                // 特殊场景：如果是从屏幕顶部状态栏（downY <= 90px）向下拉动，优先触发系统级展开通知栏或快捷控制中心
                if (downY <= 90.0f && totalDy > 60.0f && Math.abs(totalDy) > Math.abs(totalDx) * 1.2f) {
                    sMainHandler.post(() -> {
                        if (instance == null) return;
                        if (totalDy > 250.0f) {
                            Log.i(TAG, "✓ 屏幕顶端深下拉，唤起原生快捷设置控制中心 (GLOBAL_ACTION_QUICK_SETTINGS)");
                            instance.performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS);
                        } else {
                            Log.i(TAG, "✓ 屏幕顶端下拉，唤起原生状态栏通知中心 (GLOBAL_ACTION_NOTIFICATIONS)");
                            instance.performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS);
                        }
                    });
                    currentStroke = null;
                    isDispatching = false;
                    pendingFinalUp = false;
                    return;
                }

                // 场景 A：快速甩动翻页（Fling/Swipe），位移明确（> 60px）且耗时较短（< 450ms），且此前尚未派发连续碎段
                if (currentStroke == null && (Math.abs(totalDx) > 60.0f || Math.abs(totalDy) > 60.0f) && duration < 450L) {
                    sMainHandler.post(() -> {
                        if (instance == null) return;
                        try {
                            Path swipePath = new Path();
                            swipePath.moveTo(downX, downY);
                            // 针对快速左右滑动，适度延伸终点以赋予充足的翻页初速度
                            float flingEndX = currentTargetX;
                            float flingEndY = currentTargetY;
                            if (Math.abs(totalDx) > Math.abs(totalDy)) {
                                flingEndX += (totalDx > 0 ? 120.0f : -120.0f);
                                flingEndX = Math.max(0.0f, Math.min(screenW, flingEndX));
                            }
                            swipePath.lineTo(flingEndX, flingEndY);

                            GestureDescription.Builder b = new GestureDescription.Builder();
                            b.addStroke(new GestureDescription.StrokeDescription(swipePath, 0, Math.max(50L, Math.min(duration, 150L))));
                            instance.dispatchGesture(b.build(), null, null);
                            Log.i(TAG, "✓ 触发高速划动翻页 (Fling): dx=" + totalDx + ", dur=" + duration);
                        } catch (Throwable t) {
                            Log.w(TAG, "Fling 滑动异常: " + t.getMessage());
                        }
                    });
                    currentStroke = null;
                    isDispatching = false;
                    pendingFinalUp = false;

                } else {
                    // 场景 B：连续手势抬手收尾
                    if (!isDispatching) {
                        pumpContinuousGesture();
                    } else {
                        pendingFinalUp = true;
                    }
                }
            }
        }
    }

    // 智能输入缓冲区：跟踪最后一次写入的文本与时间戳，彻底消除跨进程无障碍异步更新延迟导致的单字覆盖
    private static String sLastInjectedText = "";
    private static long sLastInjectedTime = 0;

    /**
     * 电脑键盘文本输入上屏：优先剪贴板在光标处插入粘贴，备用模式下结合时间感知文本缓冲区连续流式追加，杜绝整框单字覆盖
     */
    public static void injectText(String text) {
        if (instance == null || text == null || text.isEmpty()) return;

        sMainHandler.post(() -> {
            try {
                wakeUpScreenIfNeeded();
                AccessibilityNodeInfo root = instance.getRootInActiveWindow();
                if (root == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    for (AccessibilityWindowInfo w : instance.getWindows()) {
                        if (w.isFocused() && w.getRoot() != null) {
                            root = w.getRoot();
                            break;
                        }
                    }
                }

                AccessibilityNodeInfo targetNode = null;
                if (root != null) {
                    targetNode = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                    if (targetNode == null) {
                        targetNode = findFocusedEditableNode(root);
                    }
                }

                if (targetNode != null) {
                    try {
                        targetNode.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
                    } catch (Throwable ignored) {}

                    // 1. 优先尝试系统剪贴板原生光标处粘贴（最符合自然打字体验，支持光标处插入且绝不覆盖已有文本）
                    ClipboardManager cm = (ClipboardManager) instance.getSystemService(Context.CLIPBOARD_SERVICE);
                    if (cm != null) {
                        ClipData clip = ClipData.newPlainText("ACast_Input", text);
                        cm.setPrimaryClip(clip);
                        if (targetNode.performAction(AccessibilityNodeInfo.ACTION_PASTE)) {
                            sLastInjectedText = "";
                            return;
                        }
                    }

                    // 2. 备用模式：ACTION_SET_TEXT，结合本地文本缓冲区，杜绝跨进程延迟导致的单字覆盖
                    CharSequence currentSeq = targetNode.getText();
                    String currentText = (currentSeq != null) ? currentSeq.toString() : "";

                    long now = System.currentTimeMillis();
                    String baseText;
                    // 若距离上次注入小于 1200ms，说明处于快速连续敲键打字中；若此时系统节点返回空或短于上次文本，采用缓冲区基底
                    if (now - sLastInjectedTime < 1200L && currentText.length() < sLastInjectedText.length()) {
                        baseText = sLastInjectedText;
                    } else {
                        baseText = currentText;
                    }

                    String newCombined = baseText + text;
                    sLastInjectedText = newCombined;
                    sLastInjectedTime = now;

                    Bundle arguments = new Bundle();
                    arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newCombined);
                    if (targetNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
                        return;
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

    private static AccessibilityNodeInfo findFocusedEditableNode(AccessibilityNodeInfo node) {
        if (node == null) return null;
        if (node.isFocused() && node.isEditable()) {
            return node;
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) {
                AccessibilityNodeInfo res = findFocusedEditableNode(child);
                if (res != null) return res;
            }
        }
        return null;
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
                    AccessibilityNodeInfo rootDel = instance.getRootInActiveWindow();
                    AccessibilityNodeInfo focusedDel = null;
                    if (rootDel != null) {
                        focusedDel = rootDel.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                        if (focusedDel == null) focusedDel = findFocusedEditableNode(rootDel);
                    }
                    if (focusedDel != null) {
                        CharSequence cur = focusedDel.getText();
                        String curStr = (cur != null) ? cur.toString() : "";
                        if (curStr.isEmpty() && !sLastInjectedText.isEmpty()) {
                            curStr = sLastInjectedText;
                        }
                        if (!curStr.isEmpty()) {
                            String delText = curStr.substring(0, curStr.length() - 1);
                            sLastInjectedText = delText;
                            sLastInjectedTime = System.currentTimeMillis();
                            Bundle args = new Bundle();
                            args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, delText);
                            handled = focusedDel.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
                        }
                    }
                    break;
                case 8: // KEY_ENTER (回车换行)
                    injectText("\n");
                    handled = true;
                    break;
                default:
                    Log.w(TAG, "未知的全局按键码: " + keyCode);
                    break;
            }
            Log.i(TAG, "执行全局按键映射: keyCode=" + keyCode + ", 成功=" + handled);
        });
    }
}
