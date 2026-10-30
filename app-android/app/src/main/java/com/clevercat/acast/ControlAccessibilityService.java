package com.clevercat.acast;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.graphics.Path;
import android.os.Build;
import android.util.DisplayMetrics;
import android.view.accessibility.AccessibilityEvent;

public class ControlAccessibilityService extends AccessibilityService {

    private static ControlAccessibilityService instance;

    @Override
    public void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {}

    @Override
    public void onInterrupt() {}

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        instance = null;
        return super.onUnbind(intent);
    }

    public static void injectTouch(byte action, int normX, int normY) {
        if (instance == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return;

        DisplayMetrics dm = instance.getResources().getDisplayMetrics();
        float realX = (normX / 10000.0f) * dm.widthPixels;
        float realY = (normY / 10000.0f) * dm.heightPixels;

        Path path = new Path();
        path.moveTo(realX, realY);

        GestureDescription.Builder builder = new GestureDescription.Builder();
        builder.addStroke(new GestureDescription.StrokeDescription(path, 0, 50));
        instance.dispatchGesture(builder.build(), null, null);
    }

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
        }
    }
}
