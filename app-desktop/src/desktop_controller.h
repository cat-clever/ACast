#pragma once

#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <memory>
#include "dlna_controller.h"
#include "adb_tunnel.h"
#include "auto_updater.h"

namespace acast {
namespace desktop {

using LogCallback = std::function<void(std::string)>;
using TvDeviceCallback = std::function<void(std::vector<acast::dlna::DlnaDevice>)>;
using UsbDeviceCallback = std::function<void(std::vector<acast::adb::AdbDevice>)>;
using UpdateCallback = std::function<void(acast::updater::UpdateInfo)>;
using ProgressCallback = std::function<void(std::string, int)>;

class DesktopController {
public:
    static DesktopController& GetInstance();

    void Init();
    void Cleanup();

    // 日志系统
    void SetLogCallback(LogCallback cb);
    void Log(const std::string& msg);

    // 局域网大屏设备管理
    void SetTvDeviceCallback(TvDeviceCallback cb);
    void RefreshTvDevices();
    std::vector<acast::dlna::DlnaDevice> GetTvDevices();

    // USB 手机管理与反控
    void SetUsbDeviceCallback(UsbDeviceCallback cb);
    void RefreshUsbDevices();
    std::vector<acast::adb::AdbDevice> GetUsbDevices();
    bool SendUsbBack();
    bool SendUsbHome();

    // 在线更新
    void SetUpdateCallback(UpdateCallback cb);
    void CheckUpdateAsync();
    void PerformUpdateAsync(ProgressCallback progress_cb);
    acast::updater::UpdateInfo GetLastUpdateInfo() const;

private:
    DesktopController();
    ~DesktopController();

    DesktopController(const DesktopController&) = delete;
    DesktopController& operator=(const DesktopController&) = delete;

    std::mutex mutex_;
    LogCallback log_cb_;
    TvDeviceCallback tv_cb_;
    UsbDeviceCallback usb_cb_;
    UpdateCallback update_cb_;

    std::unique_ptr<acast::dlna::DlnaController> dlna_controller_;
    std::vector<acast::dlna::DlnaDevice> tv_devices_;
    std::vector<acast::adb::AdbDevice> usb_devices_;
    acast::updater::UpdateInfo update_info_;
    bool is_discovering_ = false;
};

} // namespace desktop
} // namespace acast

