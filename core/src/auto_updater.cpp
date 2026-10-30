#include "auto_updater.h"
#include <iostream>
#include <sstream>
#include <fstream>
#include <vector>
#include <regex>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <chrono>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <unistd.h>
#include <sys/stat.h>
#elif defined(_WIN32)
#include <windows.h>
#include <direct.h>
#else
#include <unistd.h>
#include <sys/stat.h>
#endif

namespace acast {
namespace updater {

namespace {

// 执行命令行并捕获标准输出
std::string RunCommandCapture(const std::string& cmd) {
    std::string result;
    char buffer[256];
#if defined(_WIN32)
    FILE* pipe = _popen(cmd.c_str(), "r");
#else
    FILE* pipe = popen(cmd.c_str(), "r");
#endif
    if (!pipe) return "";
    while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
        result += buffer;
    }
#if defined(_WIN32)
    _pclose(pipe);
#else
    pclose(pipe);
#endif
    return result;
}

// 确保目录存在
void EnsureDirectory(const std::string& dir) {
#if defined(_WIN32)
    _mkdir(dir.c_str());
#else
    mkdir(dir.c_str(), 0755);
#endif
}

std::vector<int> ParseSemVer(std::string ver) {
    if (!ver.empty() && (ver[0] == 'v' || ver[0] == 'V')) {
        ver = ver.substr(1);
    }
    std::vector<int> parts;
    std::stringstream ss(ver);
    std::string item;
    while (std::getline(ss, item, '.')) {
        try {
            parts.push_back(std::stoi(item));
        } catch (...) {
            parts.push_back(0);
        }
    }
    while (parts.size() < 3) parts.push_back(0);
    return parts;
}

} // namespace

bool AutoUpdater::IsNewerVersion(const std::string& latest, const std::string& current) {
    auto v_latest = ParseSemVer(latest);
    auto v_curr = ParseSemVer(current);

    for (size_t i = 0; i < 3; ++i) {
        if (v_latest[i] > v_curr[i]) return true;
        if (v_latest[i] < v_curr[i]) return false;
    }
    return false;
}

std::string AutoUpdater::GetCurrentExecutablePath() {
    char path[1024] = {0};
#if defined(__APPLE__)
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0) {
        char real[1024];
        if (realpath(path, real) != nullptr) {
            return std::string(real);
        }
        return std::string(path);
    }
#elif defined(_WIN32)
    GetModuleFileNameA(NULL, path, sizeof(path));
    return std::string(path);
#else
    ssize_t count = readlink("/proc/self/exe", path, sizeof(path));
    if (count != -1) {
        return std::string(path, count);
    }
#endif
    return "";
}

UpdateInfo AutoUpdater::CheckForUpdate(const std::string& owner, const std::string& repo) {
    UpdateInfo info;
    info.current_version = CURRENT_VERSION;

    std::string api_url = "https://api.github.com/repos/" + owner + "/" + repo + "/releases/latest";
    std::string cmd = "curl -s -L -H \"User-Agent: ACast-Updater\" \"" + api_url + "\"";

    std::string response = RunCommandCapture(cmd);
    if (response.empty()) {
        return info;
    }

    // 匹配 "tag_name": "vX.Y.Z"
    std::smatch match;
    std::regex tag_regex(R"json("tag_name"\s*:\s*"([^"]+)")json");
    if (std::regex_search(response, match, tag_regex) && match.size() > 1) {
        info.latest_version = match[1].str();
    } else {
        return info;
    }

    info.has_update = IsNewerVersion(info.latest_version, info.current_version);

    // 确定适合当前平台架构的资产名称关键字
    std::string target_asset;
#if defined(__APPLE__)
    target_asset = "acast-macos-universal.dmg";
#elif defined(_WIN32)
#if defined(_M_ARM64)
    target_asset = "acast-windows-arm64.zip";
#else
    target_asset = "acast-windows-x64.zip";
#endif
#else
    target_asset = "acast-android.apk";
#endif
    info.asset_name = target_asset;

    // 匹配 browser_download_url
    // 查找包含 target_asset 的 url
    std::regex url_regex(R"json("browser_download_url"\s*:\s*"([^"]+)")json");
    auto words_begin = std::sregex_iterator(response.begin(), response.end(), url_regex);
    auto words_end = std::sregex_iterator();

    for (std::sregex_iterator i = words_begin; i != words_end; ++i) {
        std::smatch m = *i;
        std::string url = m[1].str();
        if (url.find(target_asset) != std::string::npos) {
            info.download_url = url;
            break;
        }
    }

    // 兜底下载地址
    if (info.download_url.empty()) {
        info.download_url = "https://github.com/" + owner + "/" + repo + "/releases/download/" + info.latest_version + "/" + target_asset;
    }

    return info;
}

bool AutoUpdater::DownloadFile(const std::string& url, const std::string& save_path, const std::function<void(const std::string&, int)>& cb) {
    if (cb) cb("正在下载最新安装包...", 10);
    // 使用系统 curl 极速断点续传下载
    std::string cmd = "curl -L -f -o \"" + save_path + "\" \"" + url + "\"";
    int ret = std::system(cmd.c_str());
    if (ret != 0) {
        if (cb) cb("下载失败，网络异常或资源不存在", 0);
        return false;
    }
    if (cb) cb("下载完成！", 60);
    return true;
}

bool AutoUpdater::PerformInPlaceUpdate(const UpdateInfo& info, const std::function<void(const std::string& status, int progress)>& progress_cb) {
    if (!info.has_update || info.download_url.empty()) {
        if (progress_cb) progress_cb("当前已是最新版本，无需更新。", 100);
        return false;
    }

    EnsureDirectory("update_cache");

#if defined(__APPLE__)
    std::string save_dmg = "update_cache/acast_update.dmg";
    if (!DownloadFile(info.download_url, save_dmg, progress_cb)) {
        return false;
    }
    return ApplyMacOsUpdate(save_dmg, progress_cb);
#elif defined(_WIN32)
    std::string save_zip = "update_cache/acast_update.zip";
    if (!DownloadFile(info.download_url, save_zip, progress_cb)) {
        return false;
    }
    return ApplyWindowsUpdate(save_zip, progress_cb);
#else
    if (progress_cb) progress_cb("当前平台请直接下载 APK 原地更新。", 100);
    return false;
#endif
}

#if defined(__APPLE__)
bool AutoUpdater::ApplyMacOsUpdate(const std::string& dmg_path, const std::function<void(const std::string& status, int progress)>& cb) {
    if (cb) cb("正在直接挂载 DMG 并执行原地热更新...", 75);

    // 1. 静默挂载 DMG 并获取挂载卷目录
    std::string mount_dir = "update_cache/dmg_mnt";
    EnsureDirectory(mount_dir);
    
    std::string mount_cmd = "hdiutil attach -nobrowse -readonly -mountpoint \"" + mount_dir + "\" \"" + dmg_path + "\"";
    int mount_ret = std::system(mount_cmd.c_str());
    if (mount_ret != 0) {
        if (cb) cb("挂载 DMG 失败", 0);
        return false;
    }

    // 2. 确定当前目标 App 路径
    std::string current_exe = GetCurrentExecutablePath();
    std::string target_app = "/Applications/ACast.app";

    size_t app_pos = current_exe.find(".app");
    if (app_pos != std::string::npos) {
        target_app = current_exe.substr(0, app_pos + 4);
    }

    if (cb) cb("正在准备无感替换并自动重启...", 90);

    // 3. 生成独立运行的后台热更新与自启脚本
    std::string script_path = "update_cache/apply_update.sh";
    std::ofstream script(script_path);
    if (!script.is_open()) {
        return false;
    }

    script << "#!/bin/bash\n";
    script << "sleep 1\n";
    script << "rm -rf \"" << target_app << "\"\n";
    script << "cp -R \"" << mount_dir << "/ACast.app\" \"" << target_app << "\"\n";
    script << "hdiutil detach \"" << mount_dir << "\" -force >/dev/null\n";
    script << "rm -rf update_cache\n";
    script << "open -n \"" << target_app << "\"\n";
    script.close();

    std::string chmod_cmd = "chmod +x \"" + script_path + "\"";
    std::system(chmod_cmd.c_str());

    if (cb) cb("更新完成！即将重启程序...", 100);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // 4. 后台脱离启动脚本并退出当前进程
    std::string launch_cmd = "nohup /bin/bash \"" + script_path + "\" >/dev/null </dev/null &";
    std::system(launch_cmd.c_str());
    std::exit(0);
    return true;
}
#endif

#if defined(_WIN32)
bool AutoUpdater::ApplyWindowsUpdate(const std::string& zip_path, const std::function<void(const std::string& status, int progress)>& cb) {
    if (cb) cb("正在解压新版本文件...", 75);

    std::string extract_dir = "update_cache\\extracted";
    EnsureDirectory(extract_dir);

    // 利用 Windows 原生 tar.exe 或 powershell 解压
    std::string unzip_cmd = "tar.exe -xf \"" + zip_path + "\" -C \"" + extract_dir + "\"";
    int ret = std::system(unzip_cmd.c_str());
    if (ret != 0) {
        std::string ps_unzip = "powershell -Command \"Expand-Archive -Force -Path '" + zip_path + "' -DestinationPath '" + extract_dir + "'\"";
        ret = std::system(ps_unzip.c_str());
        if (ret != 0) {
            if (cb) cb("解压更新包失败", 0);
            return false;
        }
    }

    std::string current_exe = GetCurrentExecutablePath();
    if (cb) cb("正在原地热替换并自动重启...", 90);

    // 编写后台批处理热替换脚本
    std::string bat_path = "update_cache\\apply_update.bat";
    std::ofstream bat(bat_path);
    if (!bat.is_open()) return false;

    bat << "@echo off\r\n";
    bat << "timeout /t 1 /nobreak >nul\r\n";
    bat << ":retry\r\n";
    bat << "copy /y \"" << extract_dir << "\\acast_desktop.exe\" \"" << current_exe << "\" >nul\r\n";
    bat << "if %errorlevel% neq 0 (\r\n";
    bat << "    timeout /t 1 /nobreak >nul\r\n";
    bat << "    goto retry\r\n";
    bat << ")\r\n";
    bat << "start \"\" \"" << current_exe << "\"\r\n";
    bat << "rd /s /q \"update_cache\"\r\n";
    bat << "del \"%~f0\"\r\n";
    bat.close();

    if (cb) cb("更新完成！即将重启程序...", 100);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // 启动批处理并退出当前进程
    std::string run_cmd = "start /b \"\" cmd.exe /c \"" + bat_path + "\"";
    std::system(run_cmd.c_str());
    std::exit(0);
    return true;
}
#endif

} // namespace updater
} // namespace acast

