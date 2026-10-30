#include "adb_tunnel.h"
#include <cstdio>
#include <iostream>
#include <sstream>
#include <array>
#include <memory>

#if defined(_WIN32)
#define POPEN _popen
#define PCLOSE _pclose
#else
#define POPEN popen
#define PCLOSE pclose
#endif

namespace acast {
namespace adb {

AdbTunnel::AdbTunnel() {}
AdbTunnel::~AdbTunnel() {}

std::string AdbTunnel::ExecuteCommand(const std::string& cmd) {
    std::array<char, 256> buffer;
    std::string result;
    std::unique_ptr<FILE, decltype(&PCLOSE)> pipe(POPEN(cmd.c_str(), "r"), PCLOSE);
    if (!pipe) {
        return "";
    }
    while (fgets(buffer.data(), (int)buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }
    return result;
}

bool AdbTunnel::IsAdbAvailable() {
    std::string out = ExecuteCommand("adb version");
    return out.find("Android Debug Bridge") != std::string::npos;
}

std::vector<AdbDevice> AdbTunnel::GetConnectedDevices() {
    std::vector<AdbDevice> devices;
    std::string out = ExecuteCommand("adb devices -l");
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
    std::ostringstream cmd;
    cmd << "adb -s " << serial << " forward tcp:" << local_port << " tcp:" << device_port;
    std::string out = ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectTap(const std::string& serial, int x, int y) {
    std::ostringstream cmd;
    cmd << "adb -s " << serial << " shell input tap " << x << " " << y;
    ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectSwipe(const std::string& serial, int x1, int y1, int x2, int y2, int duration_ms) {
    std::ostringstream cmd;
    cmd << "adb -s " << serial << " shell input swipe " << x1 << " " << y1 << " " << x2 << " " << y2 << " " << duration_ms;
    ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectText(const std::string& serial, const std::string& text) {
    std::ostringstream cmd;
    cmd << "adb -s " << serial << " shell input text \"" << text << "\"";
    ExecuteCommand(cmd.str());
    return true;
}

bool AdbTunnel::InjectKeyEvent(const std::string& serial, int android_keycode) {
    std::ostringstream cmd;
    cmd << "adb -s " << serial << " shell input keyevent " << android_keycode;
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
