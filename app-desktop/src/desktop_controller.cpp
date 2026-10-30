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
    fastmirror_client_ = std::make_unique<acast::fastmirror::FastMirrorClient>();
}

DesktopController::~DesktopController() {
    Cleanup();
}

void DesktopController::Init() {
    Log("ACast 控制端核心服务初始化就绪。");

    // 启动局域网对等发现服务，监听并自动发现手机发射端
    acast::discovery::PeerDiscovery::GetInstance().Start();
    acast::discovery::PeerDiscovery::GetInstance().SetPhoneListCallback([this](const std::vector<acast::discovery::DiscoveredPhone>& phones) {
        DiscoveredPhonesCallback cb;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            cb = phone_cb_;
        }
        if (cb) {
            cb(phones);
        }
    });

    // 手机端直接选择本电脑时，响应主动直连反控请求
    acast::discovery::PeerDiscovery::GetInstance().SetConnectRequestCallback([this](const acast::discovery::ConnectRequest& req) {
        Log("[局域网直连] 🎉 收到来自手机【" + req.phone_name + "】的主动连接请求，自动建立 FastMirror 反控通道...");
        ConnectWifiPhone(req.phone_ip, req.phone_port);
    });

    RefreshUsbDevices();
    CheckUpdateAsync();
}

void DesktopController::Cleanup() {
    acast::discovery::PeerDiscovery::GetInstance().Stop();
    if (dlna_controller_) {
        dlna_controller_->StopDiscovery();
    }
    if (fastmirror_client_) {
        fastmirror_client_->Disconnect();
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
    Log("[USB] 正在检测 Android 手机连接 (优先内置 ADB 工具)...");
    std::thread([this]() {
        try {
            if (!acast::adb::AdbTunnel::IsAdbAvailable()) {
                Log("[USB] 内置与系统 ADB 均未就绪，可使用局域网 Wi-Fi 投屏。");
                std::lock_guard<std::mutex> lock(mutex_);
                usb_devices_.clear();
                if (usb_cb_) usb_cb_(usb_devices_);
                return;
            }

            std::string adbPath = acast::adb::AdbTunnel::GetAdbPath();
            Log("[USB] ADB 调试桥工具已就绪: " + adbPath);

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

void DesktopController::SetFastMirrorCallback(FastMirrorCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    fm_cb_ = cb;
}

void DesktopController::SetDiscoveredPhonesCallback(DiscoveredPhonesCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    phone_cb_ = cb;
}

void DesktopController::RefreshPhones() {
    Log("[局域网] 正在全网广播搜寻手机发射端...");
    acast::discovery::PeerDiscovery::GetInstance().SearchPhones();
    RefreshUsbDevices();
}

std::vector<acast::discovery::DiscoveredPhone> DesktopController::GetDiscoveredPhones() {
    return acast::discovery::PeerDiscovery::GetInstance().GetDiscoveredPhones();
}

void DesktopController::ConnectWifiPhone(const std::string& ip, uint16_t port) {
    if (ip.empty()) {
        Log("[局域网直连] 错误：请输入有效的手机局域网 IP 地址！");
        return;
    }
    Log("[局域网直连] 正在建立 FastMirror 私有协议高速直连: " + ip + ":" + std::to_string(port) + " ...");

    std::thread([this, ip, port]() {
        bool ok = false;
        if (fastmirror_client_) {
            ok = fastmirror_client_->Connect(ip, port, 3000);
        }

        FastMirrorCallback cb_to_call;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            cb_to_call = fm_cb_;
        }

        if (ok) {
            Log("[局域网直连] 🎉 成功连接手机 FastMirror 私有协议通道 (" + ip + ":" + std::to_string(port) + ")！通信延迟 < 20ms。");
            if (cb_to_call) {
                cb_to_call(true, ip + ":" + std::to_string(port));
            }
        } else {
            Log("[局域网直连] ❌ 连接失败，请确保手机与电脑在同一局域网内，且手机端已开启投屏。");
            if (cb_to_call) {
                cb_to_call(false, "");
            }
        }
    }).detach();
}

void DesktopController::DisconnectWifiPhone() {
    if (fastmirror_client_) {
        fastmirror_client_->Disconnect();
    }
    Log("[局域网直连] 已断开手机 FastMirror 私有协议直连。");

    FastMirrorCallback cb_to_call;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        cb_to_call = fm_cb_;
    }
    if (cb_to_call) {
        cb_to_call(false, "");
    }
}

bool DesktopController::IsWifiPhoneConnected() const {
    return fastmirror_client_ && fastmirror_client_->IsConnected();
}

std::string DesktopController::GetWifiPhoneAddress() const {
    if (!fastmirror_client_ || !fastmirror_client_->IsConnected()) return "";
    return fastmirror_client_->GetConnectedIp() + ":" + std::to_string(fastmirror_client_->GetConnectedPort());
}

void DesktopController::SetVideoCallback(VideoFrameCallback cb) {
    if (fastmirror_client_) {
        fastmirror_client_->SetVideoCallback(cb);
    }
}

bool DesktopController::SendTouch(uint8_t action, uint16_t norm_x, uint16_t norm_y) {
    if (fastmirror_client_ && fastmirror_client_->IsConnected()) {
        return fastmirror_client_->SendTouch(action, norm_x, norm_y);
    }
    // 备用 USB ADB 通道
    std::vector<acast::adb::AdbDevice> devs = GetUsbDevices();
    if (!devs.empty()) {
        int x = (int)(norm_x * 1080 / 10000);
        int y = (int)(norm_y * 1920 / 10000);
        if (action == 0 || action == 2) {
            return acast::adb::AdbTunnel::InjectTap(devs[0].serial, x, y);
        }
    }
    return false;
}

bool DesktopController::SendTextInput(const std::string& text) {
    if (fastmirror_client_ && fastmirror_client_->IsConnected()) {
        return fastmirror_client_->SendTextInput(text);
    }
    std::vector<acast::adb::AdbDevice> devs = GetUsbDevices();
    if (!devs.empty()) {
        return acast::adb::AdbTunnel::InjectText(devs[0].serial, text);
    }
    return false;
}

bool DesktopController::SendKey(uint16_t key_code) {
    if (fastmirror_client_ && fastmirror_client_->IsConnected()) {
        return fastmirror_client_->SendKey(key_code);
    }
    std::vector<acast::adb::AdbDevice> devs = GetUsbDevices();
    if (!devs.empty()) {
        return acast::adb::AdbTunnel::InjectKeyEvent(devs[0].serial, (int)key_code);
    }
    return false;
}

bool DesktopController::SendBackKey() {
    // 1. 优先局域网 Wi-Fi 直连私有协议通道
    if (fastmirror_client_ && fastmirror_client_->IsConnected()) {
        Log("[私有协议反控] 触发返回键 (FastMirror KEY_BACK)...");
        return fastmirror_client_->SendBack();
    }

    // 2. 备用 USB ADB 通道
    std::vector<acast::adb::AdbDevice> devs = GetUsbDevices();
    if (!devs.empty()) {
        Log("[USB ADB 反控] 触发返回键 (KEY_BACK)...");
        return acast::adb::AdbTunnel::InjectBack(devs[0].serial);
    }

    Log("[反控] 尚未连接手机！请通过局域网 IP 直连或插入 USB 数据线。");
    return false;
}

bool DesktopController::SendHomeKey() {
    // 1. 优先局域网 Wi-Fi 直连私有协议通道
    if (fastmirror_client_ && fastmirror_client_->IsConnected()) {
        Log("[私有协议反控] 触发主页键 (FastMirror KEY_HOME)...");
        return fastmirror_client_->SendHome();
    }

    // 2. 备用 USB ADB 通道
    std::vector<acast::adb::AdbDevice> devs = GetUsbDevices();
    if (!devs.empty()) {
        Log("[USB ADB 反控] 触发主页键 (KEY_HOME)...");
        return acast::adb::AdbTunnel::InjectHome(devs[0].serial);
    }

    Log("[反控] 尚未连接手机！请通过局域网 IP 直连或插入 USB 数据线。");
    return false;
}

bool DesktopController::SendRecentsKey() {
    // 1. 优先局域网 Wi-Fi 直连私有协议通道
    if (fastmirror_client_ && fastmirror_client_->IsConnected()) {
        Log("[私有协议反控] 触发多任务键 (FastMirror KEY_APP_SWITCH)...");
        return fastmirror_client_->SendRecents();
    }

    // 2. 备用 USB ADB 通道
    std::vector<acast::adb::AdbDevice> devs = GetUsbDevices();
    if (!devs.empty()) {
        Log("[USB ADB 反控] 触发多任务键 (KEYCODE_APP_SWITCH)...");
        return acast::adb::AdbTunnel::InjectAppSwitch(devs[0].serial);
    }

    Log("[反控] 尚未连接手机！请通过局域网 IP 直连或插入 USB 数据线。");
    return false;
}

bool DesktopController::SendUsbBack() {
    return SendBackKey();
}

bool DesktopController::SendUsbHome() {
    return SendHomeKey();
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

    Log("[更新] 开始更新: " + info.latest_version + "...");
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

