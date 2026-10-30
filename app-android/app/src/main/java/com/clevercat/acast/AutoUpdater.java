package com.clevercat.acast;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;

import androidx.core.content.FileProvider;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

public class AutoUpdater {

    public interface UpdateCallback {
        void onCheckResult(boolean hasUpdate, String latestVersion, String downloadUrl);
        void onDownloadProgress(int progress, String message);
        void onError(String error);
    }

    public static void checkUpdate(Context context, UpdateCallback callback) {
        new Thread(() -> {
            try {
                URL url = new URL("https://api.github.com/repos/cat-clever/ACast/releases/latest");
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setRequestMethod("GET");
                conn.setRequestProperty("User-Agent", "ACast-Android");
                conn.setConnectTimeout(8000);
                conn.setReadTimeout(8000);

                if (conn.getResponseCode() != 200) {
                    if (callback != null) callback.onError("获取更新失败: HTTP " + conn.getResponseCode());
                    return;
                }

                BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line);
                }
                reader.close();

                JSONObject releaseJson = new JSONObject(sb.toString());
                String tagName = releaseJson.optString("tag_name", "");
                String currentVer = "0.1.1";
                try {
                    currentVer = context.getPackageManager().getPackageInfo(context.getPackageName(), 0).versionName;
                } catch (Exception ignored) {}

                String apkUrl = "";
                JSONArray assets = releaseJson.optJSONArray("assets");
                if (assets != null) {
                    for (int i = 0; i < assets.length(); i++) {
                        JSONObject asset = assets.getJSONObject(i);
                        String name = asset.optString("name", "");
                        if (name.endsWith(".apk")) {
                            apkUrl = asset.optString("browser_download_url", "");
                            break;
                        }
                    }
                }

                if (apkUrl.isEmpty()) {
                    apkUrl = "https://github.com/cat-clever/ACast/releases/download/" + tagName + "/acast-android.apk";
                }

                boolean hasUpdate = isNewer(tagName, currentVer);
                if (callback != null) {
                    callback.onCheckResult(hasUpdate, tagName, apkUrl);
                }

            } catch (Exception e) {
                if (callback != null) {
                    callback.onError("检查更新异常: " + e.getMessage());
                }
            }
        }).start();
    }

    public static void downloadAndInstall(Activity activity, String downloadUrl, UpdateCallback callback) {
        new Thread(() -> {
            try {
                if (callback != null) callback.onDownloadProgress(10, "正在连接下载最新 APK...");

                URL url = new URL(downloadUrl);
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setInstanceFollowRedirects(true);
                conn.setRequestProperty("User-Agent", "ACast-Android");
                conn.connect();

                // 处理 302 重定向
                if (conn.getResponseCode() == HttpURLConnection.HTTP_MOVED_TEMP ||
                    conn.getResponseCode() == HttpURLConnection.HTTP_MOVED_PERM) {
                    String newUrl = conn.getHeaderField("Location");
                    conn = (HttpURLConnection) new URL(newUrl).openConnection();
                    conn.setRequestProperty("User-Agent", "ACast-Android");
                    conn.connect();
                }

                int fileLength = conn.getContentLength();
                InputStream input = conn.getInputStream();

                File cacheDir = new File(activity.getExternalFilesDir(null), "Download");
                if (!cacheDir.exists()) cacheDir.mkdirs();
                File apkFile = new File(cacheDir, "acast_update.apk");

                FileOutputStream output = new FileOutputStream(apkFile);
                byte[] data = new byte[4096];
                long total = 0;
                int count;
                while ((count = input.read(data)) != -1) {
                    total += count;
                    output.write(data, 0, count);
                    if (fileLength > 0 && callback != null) {
                        int progress = (int) (total * 80 / fileLength) + 10;
                        callback.onDownloadProgress(progress, "正在下载: " + progress + "%");
                    }
                }
                output.flush();
                output.close();
                input.close();

                if (callback != null) callback.onDownloadProgress(100, "下载完成，正在调起系统安装器...");

                // 原地拉起安装器
                new Handler(Looper.getMainLooper()).post(() -> installApk(activity, apkFile));

            } catch (Exception e) {
                if (callback != null) callback.onError("下载安装失败: " + e.getMessage());
            }
        }).start();
    }

    private static void installApk(Context context, File apkFile) {
        Intent intent = new Intent(Intent.ACTION_VIEW);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            Uri apkUri = FileProvider.getUriForFile(context, context.getPackageName() + ".fileprovider", apkFile);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            intent.setDataAndType(apkUri, "application/vnd.android.package-archive");
        } else {
            intent.setDataAndType(Uri.fromFile(apkFile), "application/vnd.android.package-archive");
        }

        context.startActivity(intent);
    }

    private static boolean isNewer(String latest, String current) {
        if (latest.startsWith("v") || latest.startsWith("V")) latest = latest.substring(1);
        if (current.startsWith("v") || current.startsWith("V")) current = current.substring(1);

        String[] p1 = latest.split("\\.");
        String[] p2 = current.split("\\.");

        for (int i = 0; i < Math.max(p1.length, p2.length); i++) {
            int n1 = i < p1.length ? Integer.parseInt(p1[i]) : 0;
            int n2 = i < p2.length ? Integer.parseInt(p2[i]) : 0;
            if (n1 > n2) return true;
            if (n1 < n2) return false;
        }
        return false;
    }
}
