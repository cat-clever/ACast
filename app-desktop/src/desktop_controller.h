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
#include "peer_discovery.h"

namespace acast {
namespace desktop {

using LogCallback = std::function<void(std::string)>;
using TvDeviceCallback = std::function<void(std::vector<acast::dlna::DlnaDevice>)>;
using UsbDeviceCallback = std::function<void(std::vector<acast::adb::AdbDevice>)>;
using FastMirrorCallback = std::function<void(bool connected, std::string address)>;
using DiscoveredPhonesCallback = std::function<void(std::vector<acast::discovery::DiscoveredPhone>)>;
using VideoFrameCallback = std::function<void(const uint8_t* data, size_t size, bool is_key, int64_t pts_us)>;
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

    // 局域网 Wi-Fi 手机私有协议直连反控与自发现
    void SetFastMirrorCallback(FastMirrorCallback cb);
    void SetDiscoveredPhonesCallback(DiscoveredPhonesCallback cb);
    void SetVideoCallback(VideoFrameCallback cb);
    void RefreshPhones();
    std::vector<acast::discovery::DiscoveredPhone> GetDiscoveredPhones();
    void ConnectWifiPhone(const std::string& ip, uint16_t port = 19999);
    void DisconnectWifiPhone();
    bool IsWifiPhoneConnected() const;
    std::string GetWifiPhoneAddress() const;

    // USB 手机管理与通道检测
    void SetUsbDeviceCallback(UsbDeviceCallback cb);
    void RefreshUsbDevices();
    std::vector<acast::adb::AdbDevice> GetUsbDevices();

    // 触控与文本、按键综合反向控制 (优先局域网 FastMirror 私有协议通道，其次 ADB USB 通道)
    bool SendTouch(uint8_t action, uint16_t norm_x, uint16_t norm_y);
    bool SendTextInput(const std::string& text);
    bool SendKey(uint16_t key_code);
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
    DiscoveredPhonesCallback phone_cb_;
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

