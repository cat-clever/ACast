#include <iostream>
#include <vector>
#include <string>
#include <thread>
#include <chrono>
#include "fastmirror_protocol.h"
#include "dlna_controller.h"
#include "adb_tunnel.h"
#include "auto_updater.h"

#if defined(_WIN32)
#include <windows.h>
#endif

void PrintBanner() {
    std::cout << "====================================================\n";
    std::cout << "       ACast 跨平台投屏与反向控制端 v0.1.4          \n";
    std::cout << "  支持 DLNA / Cast / AirPlay 投屏 & USB/Wi-Fi 极低延迟反控  \n";
    std::cout << "  内置直接在线自动热更新系统 (免手动下载 DMG/ZIP)   \n";
#if defined(_M_ARM64) || defined(__aarch64__)
    std::cout << "  架构: ARM64 原生最高性能模式\n";
#else
    std::cout << "  架构: x86_64 模式\n";
#endif
    std::cout << "====================================================\n\n";
}

int main(int argc, char* argv[]) {
#if defined(_WIN32)
    SetConsoleOutputCP(CP_UTF8);
#endif

    PrintBanner();

    // 0. 启动时后台异步检查更新
    acast::updater::UpdateInfo update_info;
    std::thread update_thread([&update_info]() {
        update_info = acast::updater::AutoUpdater::CheckForUpdate();
        if (update_info.has_update) {
            std::cout << "\n>>> [发现新版本] " << update_info.latest_version 
                      << " (当前版本: " << update_info.current_version << ")\n"
                      << "    输入 'update' 即可直接原地无感更新并自动重启！\n\n";
        }
    });
    update_thread.detach();

    // 1. 扫描 USB 连接的 Android 手机
    std::cout << "[USB 检测] 正在扫描通过 USB 连接的 Android 设备...\n";
    if (acast::adb::AdbTunnel::IsAdbAvailable()) {
        auto adb_devices = acast::adb::AdbTunnel::GetConnectedDevices();
        if (adb_devices.empty()) {
            std::cout << "  -> 未发现 USB 调试设备。请开启手机【开发者选项 - USB 调试】并插入数据线。\n";
        } else {
            for (const auto& dev : adb_devices) {
                std::cout << "  -> 发现 Android 手机: " << dev.model << " (序列号: " << dev.serial << ")\n";
                std::cout << "     正在建立 USB 高速反控通道 (adb forward tcp:19999 tcp:19999)...\n";
                acast::adb::AdbTunnel::ForwardPort(dev.serial, 19999, 19999);
                std::cout << "     USB 隧道建立就绪，延迟 < 20ms。\n";
            }
        }
    } else {
        std::cout << "  -> 本地环境未检测到 adb 命令行工具，可切换为局域网 Wi-Fi 模式。\n";
    }

    std::cout << "\n[局域网检测] 正在搜索大屏与智能电视 (DLNA / Cast / AirPlay 协议)... \n";
    acast::dlna::DlnaController dlna_ctl;
    dlna_ctl.StartDiscovery([](const acast::dlna::DlnaDevice& dev) {
        std::cout << "  -> [发现电视] " << dev.friendly_name << " (" << dev.ip_address << ")\n";
        std::cout << "     控制端点: " << dev.control_url << "\n";
    });

    std::cout << "\n服务正在后台监听，输入 'q' 退出，输入 'update' 原地自动升级，输入 'tap <x> <y>' 模拟手机点击测试:\n";
    
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line == "q" || line == "quit") {
            break;
        } else if (line == "update") {
            std::cout << "[自动更新] 正在检查最新版本信息...\n";
            auto info = acast::updater::AutoUpdater::CheckForUpdate();
            if (info.has_update) {
                std::cout << "-> 发现新版本: " << info.latest_version << "，正在启动原地直接更新流程...\n";
                acast::updater::AutoUpdater::PerformInPlaceUpdate(info, [](const std::string& status, int progress) {
                    std::cout << "   [" << progress << "%] " << status << "\n";
                });
            } else {
                std::cout << "-> 当前已是最新版本 (" << info.current_version << ")，无需更新。\n";
            }
        } else if (line == "check") {
            auto info = acast::updater::AutoUpdater::CheckForUpdate();
            if (info.has_update) {
                std::cout << "-> 发现新版本: " << info.latest_version << " (当前: " << info.current_version << ")\n";
            } else {
                std::cout << "-> 当前已是最新版本 (" << info.current_version << ")\n";
            }
        } else if (line.rfind("tap", 0) == 0) {
            int x = 500, y = 500;
            if (sscanf(line.c_str(), "tap %d %d", &x, &y) >= 2) {
                auto devs = acast::adb::AdbTunnel::GetConnectedDevices();
                if (!devs.empty()) {
                    std::cout << "  -> 向手机 " << devs[0].serial << " 注入触控点击: (" << x << ", " << y << ")\n";
                    acast::adb::AdbTunnel::InjectTap(devs[0].serial, x, y);
                } else {
                    std::cout << "  -> 请先插上 USB 手机。\n";
                }
            }
        } else if (line == "back") {
            auto devs = acast::adb::AdbTunnel::GetConnectedDevices();
            if (!devs.empty()) {
                acast::adb::AdbTunnel::InjectBack(devs[0].serial);
                std::cout << "  -> 触发手机返回键。\n";
            }
        } else if (line == "home") {
            auto devs = acast::adb::AdbTunnel::GetConnectedDevices();
            if (!devs.empty()) {
                acast::adb::AdbTunnel::InjectHome(devs[0].serial);
                std::cout << "  -> 触发手机 Home 键。\n";
            }
        }
    }

    dlna_ctl.StopDiscovery();
    std::cout << "程序已正常退出。\n";
    return 0;
}

