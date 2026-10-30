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
#include <sys/types.h>
#include <pwd.h>
#elif defined(_WIN32)
#include <windows.h>
#include <direct.h>
#include <sys/stat.h>
#else
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <pwd.h>
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

// 递归确保多级目录存在
void CreateDirectoriesRecursively(const std::string& path) {
    if (path.empty()) return;
    std::string current;
    for (size_t i = 0; i < path.size(); ++i) {
        char c = path[i];
        current += c;
        if (c == '/' || c == '\\' || i == path.size() - 1) {
            if (current == "/" || current == "\\" || (current.size() == 3 && current[1] == ':' && (current[2] == '\\' || current[2] == '/'))) {
                continue;
            }
#if defined(_WIN32)
            _mkdir(current.c_str());
#else
            mkdir(current.c_str(), 0755);
#endif
        }
    }
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

std::string AutoUpdater::GetUpdateCacheDir() {
#if defined(__APPLE__)
    const char* home = std::getenv("HOME");
    std::string home_str;
    if (home && strlen(home) > 0) {
        home_str = home;
    } else {
        struct passwd* pw = getpwuid(getuid());
        if (pw && pw->pw_dir) {
            home_str = pw->pw_dir;
        }
    }
    if (!home_str.empty()) {
        std::string dir = home_str + "/Library/Caches/com.catclever.acast/update";
        CreateDirectoriesRecursively(dir);
        return dir;
    }
#elif defined(_WIN32)
    char local_app_data[MAX_PATH] = {0};
    if (GetEnvironmentVariableA("LOCALAPPDATA", local_app_data, sizeof(local_app_data)) > 0) {
        std::string dir = std::string(local_app_data) + "\\ACast\\update";
        CreateDirectoriesRecursively(dir);
        return dir;
    }
    char temp_dir[MAX_PATH] = {0};
    if (GetTempPathA(sizeof(temp_dir), temp_dir) > 0) {
        std::string dir = std::string(temp_dir) + "ACast\\update";
        CreateDirectoriesRecursively(dir);
        return dir;
    }
#else
    const char* home = std::getenv("HOME");
    if (home && strlen(home) > 0) {
        std::string dir = std::string(home) + "/.cache/acast/update";
        CreateDirectoriesRecursively(dir);
        return dir;
    }
#endif
    // 降级使用当前可执行文件所在目录
    std::string exe_path = GetCurrentExecutablePath();
    size_t last_sep = exe_path.find_last_of("/\\");
    if (last_sep != std::string::npos) {
        std::string dir = exe_path.substr(0, last_sep) + "/update_cache";
        CreateDirectoriesRecursively(dir);
        return dir;
    }
    CreateDirectoriesRecursively("update_cache");
    return "update_cache";
}

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
    std::string cmd = "curl -s -L --connect-timeout 10 -H \"User-Agent: ACast-Updater\" \"" + api_url + "\"";

    std::string response = RunCommandCapture(cmd);
    if (response.empty() || response.find("tag_name") == std::string::npos) {
        // 尝试通过备选镜像通道读取 GitHub API
        std::string mirror_api = "https://mirror.ghproxy.com/" + api_url;
        std::string mirror_cmd = "curl -s -L --connect-timeout 12 -H \"User-Agent: ACast-Updater\" \"" + mirror_api + "\"";
        response = RunCommandCapture(mirror_cmd);
    }
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

    // 删除可能存在的残留或未完成文件
    std::remove(save_path.c_str());

    auto is_valid_file = [](const std::string& path) -> bool {
        struct stat st;
        if (stat(path.c_str(), &st) == 0) {
            return st.st_size > 512 * 1024; // 安装包大小应大于 512KB
        }
        return false;
    };

    // 1. 首选通道：GitHub 直连
    std::string cmd1 = "curl -L -f -S --connect-timeout 15 --retry 2 --retry-delay 1 -o \"" + save_path + "\" \"" + url + "\"";
    int ret1 = std::system(cmd1.c_str());
    if (ret1 == 0 && is_valid_file(save_path)) {
        if (cb) cb("下载完成！", 60);
        return true;
    }

    // 2. 备选加速通道 1：mirror.ghproxy.com
    if (cb) cb("直连不稳定，正在切换高速镜像通道加速下载...", 15);
    std::remove(save_path.c_str());
    std::string mirror_url1 = "https://mirror.ghproxy.com/" + url;
    std::string cmd2 = "curl -L -f -S --connect-timeout 20 --retry 2 --retry-delay 1 -o \"" + save_path + "\" \"" + mirror_url1 + "\"";
    int ret2 = std::system(cmd2.c_str());
    if (ret2 == 0 && is_valid_file(save_path)) {
        if (cb) cb("高速下载完成！", 60);
        return true;
    }

    // 3. 备选加速通道 2：ghproxy.net
    std::remove(save_path.c_str());
    std::string mirror_url2 = "https://ghproxy.net/" + url;
    std::string cmd3 = "curl -L -f -S --connect-timeout 20 --retry 2 --retry-delay 1 -o \"" + save_path + "\" \"" + mirror_url2 + "\"";
    int ret3 = std::system(cmd3.c_str());
    if (ret3 == 0 && is_valid_file(save_path)) {
        if (cb) cb("高速下载完成！", 60);
        return true;
    }

    if (cb) cb("下载失败，网络异常或资源不存在", 0);
    return false;
}

bool AutoUpdater::PerformInPlaceUpdate(const UpdateInfo& info, const std::function<void(const std::string& status, int progress)>& progress_cb) {
    if (!info.has_update || info.download_url.empty()) {
        if (progress_cb) progress_cb("当前已是最新版本，无需更新。", 100);
        return false;
    }

    std::string cache_dir = GetUpdateCacheDir();

#if defined(__APPLE__)
    std::string save_dmg = cache_dir + "/acast_update.dmg";
    if (!DownloadFile(info.download_url, save_dmg, progress_cb)) {
        return false;
    }
    return ApplyMacOsUpdate(save_dmg, progress_cb);
#elif defined(_WIN32)
    std::string save_zip = cache_dir + "\\acast_update.zip";
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
    if (cb) cb("正在直接挂载 DMG 并执行更新...", 75);

    std::string cache_dir = GetUpdateCacheDir();
    std::string mount_dir = cache_dir + "/dmg_mnt";
    CreateDirectoriesRecursively(mount_dir);

    // 卸载可能遗留的旧挂载卷
    std::string unmount_clean = "hdiutil detach \"" + mount_dir + "\" -force >/dev/null";
    std::system(unmount_clean.c_str());

    // 1. 静默挂载 DMG 并获取挂载卷目录
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

    std::string source_app = mount_dir + "/ACast.app";

    if (cb) cb("正在准备无感替换并自动重启...", 90);

    // 3. 生成独立运行的后台热更新与自启脚本
    std::string script_path = cache_dir + "/apply_update.sh";
    std::ofstream script(script_path);
    if (!script.is_open()) {
        if (cb) cb("创建更新脚本失败", 0);
        return false;
    }

    pid_t current_pid = getpid();

    script << "#!/bin/bash\n";
    script << "# 等待当前应用主进程安全退出\n";
    script << "TARGET_PID=" << current_pid << "\n";
    script << "for i in $(seq 1 30); do\n";
    script << "    if ps -p $TARGET_PID >/dev/null; then\n";
    script << "        sleep 0.2\n";
    script << "    else\n";
    script << "        break\n";
    script << "    fi\n";
    script << "done\n";
    script << "sleep 0.5\n";
    script << "# 替换目标应用\n";
    script << "rm -rf \"" << target_app << "\"\n";
    script << "cp -R \"" << source_app << "\" \"" << target_app << "\"\n";
    script << "# 卸载挂载卷并去除隔离属性\n";
    script << "hdiutil detach \"" << mount_dir << "\" -force >/dev/null\n";
    script << "xattr -dr com.apple.quarantine \"" << target_app << "\" >/dev/null\n";
    script << "rm -rf \"" << cache_dir << "\"\n";
    script << "# 重启全新版本\n";
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

    std::string cache_dir = GetUpdateCacheDir();
    std::string extract_dir = cache_dir + "\\extracted";
    CreateDirectoriesRecursively(extract_dir);

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
    std::string bat_path = cache_dir + "\\apply_update.bat";
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
    bat << "rd /s /q \"" << cache_dir << "\"\r\n";
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
