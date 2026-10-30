#pragma once

#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <thread>
#include <atomic>
#include <chrono>

namespace acast {
namespace discovery {

constexpr uint16_t DISCOVERY_UDP_PORT = 19998;

// 局域网发现的手机设备信息
struct DiscoveredPhone {
    std::string device_id;
    std::string name;
    std::string ip;
    uint16_t port{19999};
    std::string model;
    std::chrono::steady_clock::time_point last_seen;
};

// 手机发来的直接反控连接请求
struct ConnectRequest {
    std::string phone_name;
    std::string phone_ip;
    uint16_t phone_port{19999};
};

using PhoneListCallback = std::function<void(const std::vector<DiscoveredPhone>&)>;
using ConnectRequestCallback = std::function<void(const ConnectRequest&)>;

class PeerDiscovery {
public:
    static PeerDiscovery& GetInstance();

    // 启动发现服务 (UDP 19998 广播与监听)
    void Start(const std::string& desktop_name = "");
    void Stop();

    // 全网主动广播搜寻手机
    void SearchPhones();

    // 注册已发现手机列表更新回调
    void SetPhoneListCallback(PhoneListCallback cb);

    // 注册收到手机直连请求时的回调 (手机端点击了控制端)
    void SetConnectRequestCallback(ConnectRequestCallback cb);

    // 获取当前在线的手机列表 (自动过滤已超时手机)
    std::vector<DiscoveredPhone> GetDiscoveredPhones();

private:
    PeerDiscovery();
    ~PeerDiscovery();

    void DiscoveryLoop();
    void BroadcastDesktopBeacon();
    void SendBroadcast(const std::string& json_str);
    void HandlePacket(const std::string& msg, const std::string& remote_ip);
    void PruneExpiredPhones();

    std::atomic<bool> is_running_{false};
    std::string desktop_name_;
    std::unique_ptr<std::thread> worker_thread_;
    std::mutex mutex_;
    std::vector<DiscoveredPhone> phones_;
    PhoneListCallback phone_cb_;
    ConnectRequestCallback connect_req_cb_;
    int socket_fd_{-1};
};

} // namespace discovery
} // namespace acast
