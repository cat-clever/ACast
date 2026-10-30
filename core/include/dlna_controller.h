#pragma once

#include <string>
#include <vector>
#include <functional>
#include <memory>
#include <thread>
#include <atomic>

namespace acast {
namespace dlna {

struct DlnaDevice {
    std::string uuid;
    std::string friendly_name;
    std::string location_url;
    std::string control_url;
    std::string rendering_control_url;
    std::string ip_address;
};

using DeviceFoundCallback = std::function<void(const DlnaDevice&)>;

class DlnaController {
public:
    DlnaController();
    ~DlnaController();

    // 启动 SSDP 局域网组播设备扫描
    void StartDiscovery(DeviceFoundCallback on_found);
    void StopDiscovery();

    // DLNA AVTransport 媒体控制动作 (SOAP HTTP RPC)
    bool SetAVTransportURI(const DlnaDevice& device, const std::string& media_url, const std::string& title = "ACast Live Stream");
    bool Play(const DlnaDevice& device);
    bool Pause(const DlnaDevice& device);
    bool Stop(const DlnaDevice& device);
    bool Seek(const DlnaDevice& device, const std::string& target_time = "00:00:00");
    bool SetVolume(const DlnaDevice& device, int volume); // 0 ~ 100

private:
    std::atomic<bool> is_discovering_{false};
    std::unique_ptr<std::thread> discovery_thread_;

    static std::string BuildSoapRequest(const std::string& action, const std::string& service_type, const std::string& arguments);
    static bool SendSoapAction(const std::string& host, int port, const std::string& path, const std::string& action, const std::string& soap_body);
    static bool ParseLocationXml(const std::string& location_url, DlnaDevice& out_device);
};

} // namespace dlna
} // namespace acast

