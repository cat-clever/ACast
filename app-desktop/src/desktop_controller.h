#pragma once

#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <memory>
#include "dlna_controller.h"
#include "adb_tunnel.h"
#include "auto_updater.h"
#include "fastmirror_client.h"

namespace acast {
namespace desktop {

using LogCallback = std::function<void(std::string)>;
using TvDeviceCallback = std::function<void(std::vector<acast::dlna::DlnaDevice>)>;
using UsbDeviceCallback = std::function<void(std::vector<acast::adb::AdbDevice>)>;
using FastMirrorCallback = std::function<void(bool connected, std::string address)>;
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

    // 局域网 Wi-Fi 手机私有协议直连反控
    void SetFastMirrorCallback(FastMirrorCallback cb);
    void ConnectWifiPhone(const std::string& ip, uint16_t port = 19999);
    void DisconnectWifiPhone();
    bool IsWifiPhoneConnected() const;
    std::string GetWifiPhoneAddress() const;

    // USB 手机管理与通道检测
    void SetUsbDeviceCallback(UsbDeviceCallback cb);
    void RefreshUsbDevices();
    std::vector<acast::adb::AdbDevice> GetUsbDevices();

    // 综合反向控制动作 (优先局域网 FastMirror 私有协议通道，其次 ADB USB 通道)
    bool SendBackKey();
    bool SendHomeKey();
    bool SendRecentsKey();
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
    FastMirrorCallback fm_cb_;
    UpdateCallback update_cb_;

    std::unique_ptr<acast::dlna::DlnaController> dlna_controller_;
    std::unique_ptr<acast::fastmirror::FastMirrorClient> fastmirror_client_;
    std::vector<acast::dlna::DlnaDevice> tv_devices_;
    std::vector<acast::adb::AdbDevice> usb_devices_;
    acast::updater::UpdateInfo update_info_;
    bool is_discovering_ = false;
};

} // namespace desktop
} // namespace acast

