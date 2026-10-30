#pragma once

#include <string>
#include <functional>

namespace acast {
namespace updater {

struct UpdateInfo {
    bool has_update = false;
    std::string current_version;
    std::string latest_version;
    std::string download_url;
    std::string release_notes;
    std::string asset_name;
};

class AutoUpdater {
public:
    static constexpr const char* CURRENT_VERSION = "0.2.9";

    // 检查 GitHub Releases 是否有新版本
    static UpdateInfo CheckForUpdate(const std::string& owner = "cat-clever", const std::string& repo = "ACast");

    // 一键原地直接热更新：下载、后台解压/挂载替换、唤起新版本并安全退出当前进程
    static bool PerformInPlaceUpdate(const UpdateInfo& info, const std::function<void(const std::string& status, int progress)>& progress_cb = nullptr);

    // 获取当前正在运行的可执行文件路径
    static std::string GetCurrentExecutablePath();

    // 语义化版本号比较 (latest > current 则返回 true)
    static bool IsNewerVersion(const std::string& latest, const std::string& current);

    // 获取标准平台规范的用户级持久化缓存目录
    static std::string GetUpdateCacheDir();

private:
    static bool DownloadFile(const std::string& url, const std::string& save_path, const std::function<void(const std::string& status, int progress)>& cb);
    static bool ApplyMacOsUpdate(const std::string& dmg_path, const std::function<void(const std::string& status, int progress)>& cb);
    static bool ApplyWindowsUpdate(const std::string& zip_path, const std::function<void(const std::string& status, int progress)>& cb);
};

} // namespace updater
} // namespace acast
