#pragma once

#include <string>
#include <vector>

namespace acast {
namespace adb {

struct AdbDevice {
    std::string serial;
    std::string state;
    std::string model;
};

class AdbTunnel {
public:
    AdbTunnel();
    ~AdbTunnel();

    // 检查本地或内置是否有 adb 工具可用
    static bool IsAdbAvailable();

    // 获取当前生效的 adb 可执行文件路径
    static std::string GetAdbPath();

    // 获取当前已连接的 Android USB 设备列表
    static std::vector<AdbDevice> GetConnectedDevices();

    // 端口映射：把 PC 本地端口转发给 Android 手机内部端口 (adb forward tcp:19999 tcp:19999)
    static bool ForwardPort(const std::string& serial, int local_port, int device_port);

    // 异步非阻塞反向控制注入（UI 线程耗时 0ms，彻底杜绝主线程假死与彩球）
    static bool InjectTap(const std::string& serial, int x, int y);
    static bool InjectSwipe(const std::string& serial, int x1, int y1, int x2, int y2, int duration_ms = 100);
    static bool InjectText(const std::string& serial, const std::string& text);
    static bool InjectKeyEvent(const std::string& serial, int android_keycode);
    static bool InjectBack(const std::string& serial);
    static bool InjectHome(const std::string& serial);
    static bool InjectAppSwitch(const std::string& serial);

    // 同步执行（仅用于初始化检测、获取设备列表等低频后台线程操作）
    static std::string ExecuteCommand(const std::string& cmd);

    // 异步非阻塞执行（用于高频反向控制，支持手势背压防积压丢弃）
    static void ExecuteCommandAsync(const std::string& cmd, bool is_gesture = false);

private:
    static std::string GetCurrentExecutablePath();
    static bool EnsureBuiltinAdbDownloaded();
};

} // namespace adb
} // namespace acast

