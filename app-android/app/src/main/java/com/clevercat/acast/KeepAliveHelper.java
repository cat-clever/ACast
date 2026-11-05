package com.clevercat.acast;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.Log;
import android.widget.Toast;

import androidx.appcompat.app.AlertDialog;

/**
 * KeepAliveHelper: 手机端全方位后台保活与防杀管理助手
 * 支持：
 * 1. 原生 Doze 电池优化白名单检测与一键申请 (ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
 * 2. 小米/红米 (MIUI/HyperOS)、华为/荣耀、OPPO、vivo 等主流国产系统的自启动与省电策略一键跳转
 * 3. 智能多任务卡片加锁与防一键清理引导
 */
public class KeepAliveHelper {

    private static final String TAG = "KeepAliveHelper";

    /**
     * 检测当前应用是否已成功加入系统电池优化白名单 (无限制模式)
     */
    public static boolean isIgnoringBatteryOptimizations(Context context) {
        if (context == null) return false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
                if (pm != null) {
                    return pm.isIgnoringBatteryOptimizations(context.getPackageName());
                }
            } catch (Throwable t) {
                Log.w(TAG, "检测电池优化白名单状态异常: " + t.getMessage());
            }
        }
        return true;
    }

    /**
     * 一键申请系统电池优化白名单 (弹出系统原生授权对话框)
     */
    public static void requestIgnoreBatteryOptimizations(Activity activity) {
        if (activity == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                if (!isIgnoringBatteryOptimizations(activity)) {
                    Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                    intent.setData(Uri.parse("package:" + activity.getPackageName()));
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    activity.startActivity(intent);
                } else {
                    Toast.makeText(activity, "✓ 当前应用已加入电池优化白名单 (无限制运行)", Toast.LENGTH_SHORT).show();
                }
            } catch (Throwable t) {
                Log.w(TAG, "申请忽略电池优化异常，回退至列表页: " + t.getMessage());
                try {
                    Intent fallback = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
                    fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    activity.startActivity(fallback);
                } catch (Throwable ignored) {
                    jumpToAppDetail(activity);
                }
            }
        }
    }

    /**
     * 智能识别厂商并一键跳转系统的【自启动管理】与【后台省电策略】页面
     */
    public static void jumpToAutoStartOrBatterySettings(Context context) {
        if (context == null) return;
        String brand = (Build.BRAND != null ? Build.BRAND : "").toLowerCase();
        String manufacturer = (Build.MANUFACTURER != null ? Build.MANUFACTURER : "").toLowerCase();

        Intent intent = new Intent();
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);

        try {
            if (brand.contains("xiaomi") || brand.contains("redmi") || manufacturer.contains("xiaomi")) {
                // 小米 / 红米 (MIUI / HyperOS 澎湃OS)
                try {
                    // 优先跳转自启动管理页
                    intent.setComponent(new ComponentName(
                            "com.miui.securitycenter",
                            "com.miui.permcenter.autostart.AutoStartManagementActivity"
                    ));
                    context.startActivity(intent);
                    return;
                } catch (Throwable e1) {
                    try {
                        // 备选跳转小米省电策略配置页
                        Intent powerIntent = new Intent();
                        powerIntent.setComponent(new ComponentName(
                                "com.miui.securitycenter",
                                "com.miui.powercenter.PowerSettings"
                        ));
                        powerIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                        context.startActivity(powerIntent);
                        return;
                    } catch (Throwable ignored) {}
                }

            } else if (brand.contains("huawei") || brand.contains("honor") || manufacturer.contains("huawei")) {
                // 华为 / 荣耀 (EMUI / HarmonyOS 鸿蒙)
                try {
                    intent.setComponent(new ComponentName(
                            "com.huawei.systemmanager",
                            "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                    ));
                    context.startActivity(intent);
                    return;
                } catch (Throwable e1) {
                    try {
                        intent.setComponent(new ComponentName(
                                "com.huawei.systemmanager",
                                "com.huawei.systemmanager.optimize.bootstart.BootStartActivity"
                        ));
                        context.startActivity(intent);
                        return;
                    } catch (Throwable ignored) {}
                }

            } else if (brand.contains("oppo") || brand.contains("realme") || manufacturer.contains("oppo")) {
                // OPPO / 一加 / 真我 (ColorOS)
                try {
                    intent.setComponent(new ComponentName(
                            "com.coloros.safecenter",
                            "com.coloros.safecenter.startupapp.StartupAppListActivity"
                    ));
                    context.startActivity(intent);
                    return;
                } catch (Throwable e1) {
                    try {
                        intent.setComponent(new ComponentName(
                                "com.oppo.safe",
                                "com.oppo.safe.permission.startup.StartupAppListActivity"
                        ));
                        context.startActivity(intent);
                        return;
                    } catch (Throwable ignored) {}
                }

            } else if (brand.contains("vivo") || brand.contains("iqoo") || manufacturer.contains("vivo")) {
                // vivo / iQOO (OriginOS / FuntouchOS)
                try {
                    intent.setComponent(new ComponentName(
                            "com.vivo.permissionmanager",
                            "com.vivo.permissionmanager.activity.PurviewTabActivity"
                    ));
                    context.startActivity(intent);
                    return;
                } catch (Throwable e1) {
                    try {
                        intent.setComponent(new ComponentName(
                                "com.iqoo.secure",
                                "com.iqoo.secure.ui.phoneoptimize.SoftwareManagerActivity"
                        ));
                        context.startActivity(intent);
                        return;
                    } catch (Throwable ignored) {}
                }

            } else if (brand.contains("samsung") || manufacturer.contains("samsung")) {
                // 三星 (One UI)
                try {
                    intent.setComponent(new ComponentName(
                            "com.samsung.android.lool",
                            "com.samsung.android.sm.ui.battery.BatteryActivity"
                    ));
                    context.startActivity(intent);
                    return;
                } catch (Throwable ignored) {}
            }

            // 其他厂商或跳转失败，通用降级至应用详情页
            jumpToAppDetail(context);

        } catch (Throwable t) {
            Log.w(TAG, "厂商设置跳转异常: " + t.getMessage());
            jumpToAppDetail(context);
        }
    }

    /**
     * 降级方案：跳转当前应用系统详情页 (应用管理)
     */
    public static void jumpToAppDetail(Context context) {
        if (context == null) return;
        try {
            Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
            intent.setData(Uri.parse("package:" + context.getPackageName()));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(intent);
        } catch (Throwable t) {
            try {
                Intent fallback = new Intent(Settings.ACTION_SETTINGS);
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(fallback);
            } catch (Throwable ignored) {}
        }
    }

    /**
     * 弹出后台保活与防杀全攻略指引弹窗
     */
    public static void showKeepAliveDialog(Activity activity, Runnable onUpdated) {
        if (activity == null || activity.isFinishing()) return;

        String brand = (Build.BRAND != null ? Build.BRAND : "").toUpperCase();
        boolean hasBatteryWhite = isIgnoringBatteryOptimizations(activity);

        StringBuilder sb = new StringBuilder();
        sb.append("为了保证投屏在手机锁屏、息屏以及切换到其他应用时稳定持续运行，请确认以下设置：\n\n");
        sb.append("1. 【电池策略/省电策略】设为【无限制】\n");
        sb.append("   状态: ").append(hasBatteryWhite ? "✓ 已开启 (无限制)" : "⚠️ 尚未加入白名单 (锁屏易断连)").append("\n\n");
        sb.append("2. 【自启动与后台运行权限】\n");
        sb.append("   请在系统设置中允许 ACast【自启动】与【允许后台活动】\n\n");
        sb.append("3. 【多任务卡片加锁】\n");
        sb.append("   在手机多任务界面长按或向下拉动 ACast 卡片并点击【锁形图标】，防止被系统一键清理杀后台。");

        AlertDialog.Builder builder = new AlertDialog.Builder(activity);
        builder.setTitle("🛡️ 后台保活与防杀配置 (" + brand + ")");
        builder.setMessage(sb.toString());

        if (!hasBatteryWhite) {
            builder.setPositiveButton("一键忽略电池优化", (dialog, which) -> {
                requestIgnoreBatteryOptimizations(activity);
                if (onUpdated != null) onUpdated.run();
            });
            builder.setNeutralButton("跳转自启动设置", (dialog, which) -> {
                jumpToAutoStartOrBatterySettings(activity);
                if (onUpdated != null) onUpdated.run();
            });
        } else {
            builder.setPositiveButton("去系统设置检查", (dialog, which) -> {
                jumpToAutoStartOrBatterySettings(activity);
                if (onUpdated != null) onUpdated.run();
            });
        }

        builder.setNegativeButton("知道了", (dialog, which) -> {
            dialog.dismiss();
            if (onUpdated != null) onUpdated.run();
        });

        builder.show();
    }
}
