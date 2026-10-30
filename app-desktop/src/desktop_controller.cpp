#include "desktop_controller.h"
#include <iostream>
#include <sstream>
#include <iomanip>
#include <chrono>
#include <thread>
#include <algorithm>

namespace acast {
namespace desktop {

static std::string GetCurrentTimestamp() {
    auto now = std::chrono::system_clock::now();
    auto in_time_t = std::chrono::system_clock::to_time_t(now);
    std::stringstream ss;
    ss << std::put_time(std::localtime(&in_time_t), "%H:%M:%S");
    return ss.str();
}

DesktopController& DesktopController::GetInstance() {
    static DesktopController instance;
    return instance;
}

DesktopController::DesktopController() {
    dlna_controller_ = std::make_unique<acast::dlna::DlnaController>();
}

DesktopController::~DesktopController() {
    Cleanup();
}

void DesktopController::Init() {
    Log("ACast 控制端核心服务初始化就绪。");
    RefreshUsbDevices();
    RefreshTvDevices();
    CheckUpdateAsync();
}

void DesktopController::Cleanup() {
    if (dlna_controller_) {
        dlna_controller_->StopDiscovery();
    }
}

void DesktopController::SetLogCallback(LogCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    log_cb_ = cb;
}

void DesktopController::Log(const std::string& msg) {
    std::string line = "[" + GetCurrentTimestamp() + "] " + msg;
    LogCallback cb_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        cb_copy = log_cb_;
    }
    if (cb_copy) {
        cb_copy(line);
    }
}

void DesktopController::SetTvDeviceCallback(TvDeviceCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    tv_cb_ = cb;
}

void DesktopController::RefreshTvDevices() {
    Log("[局域网] 开始组播搜索大屏电视 (DLNA / Cast / AirPlay)...");
    
    {
        std::lock_guard<std::mutex> lock(mutex_);
        tv_devices_.clear();
    }
    
    // 停止上一次搜索
    if (dlna_controller_) {
        dlna_controller_->StopDiscovery();
    }

    std::thread([this]() {
        try {
            dlna_controller_->StartDiscovery([this](const acast::dlna::DlnaDevice& dev) {
                bool is_new = false;
                std::vector<acast::dlna::DlnaDevice> copy_list;
                TvDeviceCallback cb_to_call;

                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    // 根据 ip 和 friendly_name 去重
                    auto it = std::find_if(tv_devices_.begin(), tv_devices_.end(), [&](const acast::dlna::DlnaDevice& item) {
                        return item.ip_address == dev.ip_address && item.friendly_name == dev.friendly_name;
                    });
                    if (it == tv_devices_.end()) {
                        tv_devices_.push_back(dev);
                        copy_list = tv_devices_;
                        cb_to_call = tv_cb_;
                        is_new = true;
                    }
                }

                if (is_new) {
                    Log("[发现大屏] " + dev.friendly_name + " (" + dev.ip_address + ")");
                    if (cb_to_call) {
                        cb_to_call(copy_list);
                    }
                }
            });
        } catch (const std::exception& e) {
            Log(std::string("[异常] 局域网大屏搜索异常: ") + e.what());
        } catch (...) {
            Log("[异常] 局域网大屏搜索发生未知异常");
        }
    }).detach();
}

std::vector<acast::dlna::DlnaDevice> DesktopController::GetTvDevices() {
    std::lock_guard<std::mutex> lock(mutex_);
    return tv_devices_;
}

void DesktopController::SetUsbDeviceCallback(UsbDeviceCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    usb_cb_ = cb;
}

void DesktopController::RefreshUsbDevices() {
    Log("[USB] 正在扫描通过 USB 连接的 Android 手机...");
    std::thread([this]() {
        try {
            if (!acast::adb::AdbTunnel::IsAdbAvailable()) {
                Log("[USB] 本地未检测到 adb 命令行工具，可使用局域网 Wi-Fi 投屏。");
                std::lock_guard<std::mutex> lock(mutex_);
                usb_devices_.clear();
                if (usb_cb_) usb_cb_(usb_devices_);
                return;
            }

            auto devs = acast::adb::AdbTunnel::GetConnectedDevices();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                usb_devices_ = devs;
            }

            if (devs.empty()) {
                Log("[USB] 未检测到 USB 调试设备。请开启手机【开发者选项 - USB 调试】并插上数据线。");
            } else {
                for (const auto& dev : devs) {
                    Log("[USB] 发现手机: " + dev.model + " (SN: " + dev.serial + ", 状态: " + dev.state + ")");
                    Log("[USB] 建立高速反控端口转发 (adb forward tcp:19999 tcp:19999)...");
                    bool ok = acast::adb::AdbTunnel::ForwardPort(dev.serial, 19999, 19999);
                    if (ok) {
                        Log("[USB] 高速反控通道建立成功，触控延迟 < 20ms。");
                    } else {
                        Log("[USB] 端口转发建立失败，请检查手机 ADB 授权状态。");
                    }
                }
            }

            UsbDeviceCallback cb_to_call;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                cb_to_call = usb_cb_;
            }
            if (cb_to_call) {
                cb_to_call(devs);
            }
        } catch (const std::exception& e) {
            Log(std::string("[异常] USB 扫描异常: ") + e.what());
        } catch (...) {
            Log("[异常] USB 扫描发生未知错误");
        }
    }).detach();
}

std::vector<acast::adb::AdbDevice> DesktopController::GetUsbDevices() {
    std::lock_guard<std::mutex> lock(mutex_);
    return usb_devices_;
}

bool DesktopController::SendUsbBack() {
    std::vector<acast::adb::AdbDevice> devs = GetUsbDevices();
    if (devs.empty()) {
        Log("[反控] 未连接手机，无法触发返回键。");
        return false;
    }
    Log("[反控] 触发手机返回键 (KEY_BACK)...");
    return acast::adb::AdbTunnel::InjectBack(devs[0].serial);
}

bool DesktopController::SendUsbHome() {
    std::vector<acast::adb::AdbDevice> devs = GetUsbDevices();
    if (devs.empty()) {
        Log("[反控] 未连接手机，无法触发主页键。");
        return false;
    }
    Log("[反控] 触发手机主页键 (KEY_HOME)...");
    return acast::adb::AdbTunnel::InjectHome(devs[0].serial);
}

void DesktopController::SetUpdateCallback(UpdateCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    update_cb_ = cb;
}

void DesktopController::CheckUpdateAsync() {
    Log("[更新] 正在检查 GitHub Releases 最新版本...");
    std::thread([this]() {
        try {
            auto info = acast::updater::AutoUpdater::CheckForUpdate();
            UpdateCallback cb_to_call;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                update_info_ = info;
                cb_to_call = update_cb_;
            }

            if (info.has_update) {
                Log("[更新] 🎉 发现新版本: " + info.latest_version + " (当前: " + info.current_version + ")");
                Log("[更新] 点击【一键更新】即可原地自动无感升级并重启！");
            } else {
                Log("[更新] 当前已是最新版本 (" + info.current_version + ")。");
            }

            if (cb_to_call) {
                cb_to_call(info);
            }
        } catch (const std::exception& e) {
            Log(std::string("[更新] 检查更新失败: ") + e.what());
        } catch (...) {
            Log("[更新] 检查更新发生未知异常");
        }
    }).detach();
}

void DesktopController::PerformUpdateAsync(ProgressCallback progress_cb) {
    acast::updater::UpdateInfo info = GetLastUpdateInfo();
    if (!info.has_update) {
        Log("[更新] 当前已是最新版本，无需更新。");
        if (progress_cb) progress_cb("当前已是最新版本", 100);
        return;
    }

    Log("[更新] 开始原地热更新: " + info.latest_version + "...");
    std::thread([this, info, progress_cb]() {
        try {
            bool ok = acast::updater::AutoUpdater::PerformInPlaceUpdate(info, [this, progress_cb](const std::string& status, int progress) {
                Log("[更新进度 " + std::to_string(progress) + "%] " + status);
                if (progress_cb) progress_cb(status, progress);
            });
            if (!ok) {
                Log("[更新] 原地更新失败，请检查网络或写入权限。");
            }
        } catch (const std::exception& e) {
            Log(std::string("[更新异常] ") + e.what());
        } catch (...) {
            Log("[更新异常] 未知错误");
        }
    }).detach();
}

acast::updater::UpdateInfo DesktopController::GetLastUpdateInfo() const {
    return update_info_;
}

} // namespace desktop
} // namespace acast
