#include "adb_tunnel.h"
#include <cstdio>
#include <iostream>
#include <sstream>
#include <array>
#include <memory>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <sys/stat.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <unistd.h>
#elif defined(_WIN32)
#include <windows.h>
#include <direct.h>
#else
#include <unistd.h>
#endif

namespace acast {
namespace adb {

namespace {

void MkdirRecursive(const std::string& dir) {
    if (dir.empty()) return;
    std::string current;
    for (size_t i = 0; i < dir.size(); ++i) {
        char c = dir[i];
        current += c;
        if (c == '/' || c == '\\' || i == dir.size() - 1) {
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

} // namespace

AdbTunnel::AdbTunnel() {}
AdbTunnel::~AdbTunnel() {}

std::string AdbTunnel::GetCurrentExecutablePath() {
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

bool AdbTunnel::EnsureBuiltinAdbDownloaded() {
#if defined(__APPLE__)
    const char* home = std::getenv("HOME");
    if (!home) return false;
    std::string tools_dir = std::string(home) + "/Library/Caches/com.catclever.acast/tools";
    MkdirRecursive(tools_dir);
    std::string target_adb = tools_dir + "/adb";
    if (access(target_adb.c_str(), X_OK) == 0) {
        return true;
    }

    std::string zip_path = tools_dir + "/pt_darwin.zip";
    std::string dl_cmd = "curl -L -f -S --connect-timeout 15 --retry 2 -o \"" + zip_path + "\" \"https://dl.google.com/android/repository/platform-tools-latest-darwin.zip\"";
    int ret = std::system(dl_cmd.c_str());
    if (ret != 0) {
        std::string mirror_cmd = "curl -L -f -S --connect-timeout 15 --retry 2 -o \"" + zip_path + "\" \"https://mirror.ghproxy.com/https://dl.google.com/android/repository/platform-tools-latest-darwin.zip\"";
        ret = std::system(mirror_cmd.c_str());
    }
    if (ret == 0) {
        std::string unzip_cmd = "unzip -q -o \"" + zip_path + "\" platform-tools/adb -d \"" + tools_dir + "\"";
        std::system(unzip_cmd.c_str());
        std::string mv_cmd = "mv \"" + tools_dir + "/platform-tools/adb\" \"" + target_adb + "\"";
        std::system(mv_cmd.c_str());
        std::string chmod_cmd = "chmod +x \"" + target_adb + "\"";
        std::system(chmod_cmd.c_str());
        std::remove(zip_path.c_str());
        if (access(target_adb.c_str(), X_OK) == 0) {
            return true;
        }
    }
#elif defined(_WIN32)
    char local_app_data[MAX_PATH] = {0};
    if (GetEnvironmentVariableA("LOCALAPPDATA", local_app_data, sizeof(local_app_data)) <= 0) return false;
    std::string tools_dir = std::string(local_app_data) + "\\ACast\\tools";
    MkdirRecursive(tools_dir);
    std::string target_adb = tools_dir + "\\adb.exe";
    DWORD attr = GetFileAttributesA(target_adb.c_str());
    if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
        return true;
    }

    std::string zip_path = tools_dir + "\\pt_windows.zip";
    std::string dl_cmd = "curl.exe -L -f -S --connect-timeout 15 --retry 2 -o \"" + zip_path + "\" \"https://dl.google.com/android/repository/platform-tools-latest-windows.zip\"";
    int ret = std::system(dl_cmd.c_str());
    if (ret != 0) {
        std::string mirror_cmd = "curl.exe -L -f -S --connect-timeout 15 --retry 2 -o \"" + zip_path + "\" \"https://mirror.ghproxy.com/https://dl.google.com/android/repository/platform-tools-latest-windows.zip\"";
        ret = std::system(mirror_cmd.c_str());
    }
    if (ret == 0) {
        std::string unzip_cmd = "tar.exe -xf \"" + zip_path + "\" -C \"" + tools_dir + "\"";
        std::system(unzip_cmd.c_str());
        std::string move_adb = "copy /y \"" + tools_dir + "\\platform-tools\\adb.exe\" \"" + target_adb + "\" >nul";
        std::system(move_adb.c_str());
        std::string move_dll1 = "copy /y \"" + tools_dir + "\\platform-tools\\AdbWinApi.dll\" \"" + tools_dir + "\\AdbWinApi.dll\" >nul";
        std::system(move_dll1.c_str());
        std::string move_dll2 = "copy /y \"" + tools_dir + "\\platform-tools\\AdbWinUsbApi.dll\" \"" + tools_dir + "\\AdbWinUsbApi.dll\" >nul";
        std::system(move_dll2.c_str());
        std::remove(zip_path.c_str());
        attr = GetFileAttributesA(target_adb.c_str());
        if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
            return true;
        }
    }
#endif
    return false;
}

std::string AdbTunnel::GetAdbPath() {
    static std::string cached_adb_path = "";
    if (!cached_adb_path.empty()) {
        return cached_adb_path;
    }

    std::string exe_path = GetCurrentExecutablePath();
    size_t last_sep = exe_path.find_last_of("/\\");
    std::string exe_dir = (last_sep != std::string::npos) ? exe_path.substr(0, last_sep) : "";

    // 1. 优先查找当前运行目录或应用 Bundle 内置的 adb
#if defined(_WIN32)
    if (!exe_dir.empty()) {
        std::string local_adb = exe_dir + "\\adb.exe";
        DWORD attr = GetFileAttributesA(local_adb.c_str());
        if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
            cached_adb_path = "\"" + local_adb + "\"";
            return cached_adb_path;
        }
    }
#else
    if (!exe_dir.empty()) {
        std::string local_adb = exe_dir + "/adb";
        if (access(local_adb.c_str(), X_OK) == 0) {
            cached_adb_path = "\"" + local_adb + "\"";
            return cached_adb_path;
        }
    }
#endif

    // 2. 检查应用持久化工具缓存目录
#if defined(__APPLE__)
    const char* home = std::getenv("HOME");
    if (home) {
        std::string cached_adb = std::string(home) + "/Library/Caches/com.catclever.acast/tools/adb";
        if (access(cached_adb.c_str(), X_OK) == 0) {
            cached_adb_path = "\"" + cached_adb + "\"";
            return cached_adb_path;
        }
    }
#elif defined(_WIN32)
    char local_app_data[MAX_PATH] = {0};
    if (GetEnvironmentVariableA("LOCALAPPDATA", local_app_data, sizeof(local_app_data)) > 0) {
        std::string cached_adb = std::string(local_app_data) + "\\ACast\\tools\\adb.exe";
        DWORD attr = GetFileAttributesA(cached_adb.c_str());
        if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
            cached_adb_path = "\"" + cached_adb + "\"";
            return cached_adb_path;
        }
    }
#endif

    // 3. 检查系统常见开发路径与环境变量 (ANDROID_HOME / ANDROID_SDK_ROOT)
    const char* android_home = std::getenv("ANDROID_HOME");
    if (!android_home) android_home = std::getenv("ANDROID_SDK_ROOT");
    if (android_home) {
#if defined(_WIN32)
        std::string sdk_adb = std::string(android_home) + "\\platform-tools\\adb.exe";
        DWORD attr = GetFileAttributesA(sdk_adb.c_str());
        if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
            cached_adb_path = "\"" + sdk_adb + "\"";
            return cached_adb_path;
        }
#else
        std::string sdk_adb = std::string(android_home) + "/platform-tools/adb";
        if (access(sdk_adb.c_str(), X_OK) == 0) {
            cached_adb_path = "\"" + sdk_adb + "\"";
            return cached_adb_path;
        }
#endif
    }

#if defined(__APPLE__)
    std::vector<std::string> common_paths = {
        std::string(home ? home : "") + "/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb"
    };
    for (const auto& path : common_paths) {
        if (!path.empty() && access(path.c_str(), X_OK) == 0) {
            cached_adb_path = "\"" + path + "\"";
            return cached_adb_path;
        }
    }
#elif defined(_WIN32)
    if (local_app_data[0] != '\0') {
        std::string win_sdk_adb = std::string(local_app_data) + "\\Android\\Sdk\\platform-tools\\adb.exe";
        DWORD attr = GetFileAttributesA(win_sdk_adb.c_str());
        if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
            cached_adb_path = "\"" + win_sdk_adb + "\"";
            return cached_adb_path;
        }
    }
#endif

    // 4. 检查系统全局 PATH 中的 adb 命令
    std::string test_cmd = "adb version";
    std::string out = ExecuteCommand(test_cmd);
    if (out.find("Android Debug Bridge") != std::string::npos) {
        cached_adb_path = "adb";
        return cached_adb_path;
    }

    // 5. 兜底自动补全：自动静默配置内置 ADB 工具
    if (EnsureBuiltinAdbDownloaded()) {
#if defined(__APPLE__)
        if (home) {
            cached_adb_path = "\"" + std::string(home) + "/Library/Caches/com.catclever.acast/tools/adb\"";
            return cached_adb_path;
        }
#elif defined(_WIN32)
        if (local_app_data[0] != '\0') {
            cached_adb_path = "\"" + std::string(local_app_data) + "\\ACast\\tools\\adb.exe\"";
            return cached_adb_path;
        }
#endif
    }

    return "";
}

std::string AdbTunnel::ExecuteCommand(const std::string& cmd) {
    std::array<char, 256> buffer;
    std::string result;
#if defined(_WIN32)
    std::string wrapped_cmd = "\"" + cmd + "\"";
    FILE* pipe = _popen(wrapped_cmd.c_str(), "r");
#else
    FILE* pipe = popen(cmd.c_str(), "r");
#endif
    if (!pipe) {
        return "";
    }
    while (fgets(buffer.data(), (int)buffer.size(), pipe) != nullptr) {
        result += buffer.data();
    }
#if defined(_WIN32)
    _pclose(pipe);
#else
    pclose(pipe);
#endif
    return result;
}

bool AdbTunnel::IsAdbAvailable() {
    std::string adb = GetAdbPath();
    if (adb.empty()) return false;
    std::string out = ExecuteCommand(adb + " version");
    return out.find("Android Debug Bridge") != std::string::npos;
}

std::vector<AdbDevice> AdbTunnel::GetConnectedDevices() {
    std::vector<AdbDevice> devices;
    std::string adb = GetAdbPath();
    if (adb.empty()) return devices;

    std::string out = ExecuteCommand(adb + " devices -l");
    std::istringstream stream(out);
    std::string line;

    while (std::getline(stream, line)) {
        if (line.empty() || line.find("List of devices") != std::string::npos) {
            continue;
        }
        std::istringstream line_stream(line);
        std::string serial, state;
        if (line_stream >> serial >> state) {
            AdbDevice dev;
            dev.serial = serial;
            dev.state = state;
            
            // 提取 model
            std::string token;
            while (line_stream >> token) {
                if (token.rfind("model:", 0) == 0) {
                    dev.model = token.substr(6);
                }
            }
            if (dev.model.empty()) dev.model = "Android 设备";
            devices.push_back(dev);
        }
    }
    return devices;
}

bool AdbTunnel::ForwardPort(const std::string& serial, int local_port, int device_port) {
    std::string adb = GetAdbPath();
    if (adb.empty()) return false;
    std::ostringstream cmd;
    cmd << adb << " -s " << serial << " forward tcp:" << local_port << " tcp:" << device_port;
    ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectTap(const std::string& serial, int x, int y) {
    std::string adb = GetAdbPath();
    if (adb.empty()) return false;
    std::ostringstream cmd;
    cmd << adb << " -s " << serial << " shell input tap " << x << " " << y;
    ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectSwipe(const std::string& serial, int x1, int y1, int x2, int y2, int duration_ms) {
    std::string adb = GetAdbPath();
    if (adb.empty()) return false;
    std::ostringstream cmd;
    cmd << adb << " -s " << serial << " shell input swipe " << x1 << " " << y1 << " " << x2 << " " << y2 << " " << duration_ms;
    ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectText(const std::string& serial, const std::string& text) {
    std::string adb = GetAdbPath();
    if (adb.empty()) return false;
    std::ostringstream cmd;
    cmd << adb << " -s " << serial << " shell input text \"" << text << "\"";
    ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectKeyEvent(const std::string& serial, int android_keycode) {
    std::string adb = GetAdbPath();
    if (adb.empty()) return false;
    std::ostringstream cmd;
    cmd << adb << " -s " << serial << " shell input keyevent " << android_keycode;
    ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectBack(const std::string& serial) {
    return InjectKeyEvent(serial, 4); // KEYCODE_BACK = 4
}

bool AdbTunnel::InjectHome(const std::string& serial) {
    return InjectKeyEvent(serial, 3); // KEYCODE_HOME = 3
}

bool AdbTunnel::InjectAppSwitch(const std::string& serial) {
    return InjectKeyEvent(serial, 187); // KEYCODE_APP_SWITCH = 187
}

} // namespace adb
} // namespace acast
