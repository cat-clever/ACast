#pragma once

#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <cstdint>
#include "fastmirror_protocol.h"

namespace acast {
namespace fastmirror {

class FastMirrorClient {
public:
    FastMirrorClient();
    ~FastMirrorClient();

    // 建立局域网 Wi-Fi IP 或本机端口连接
    bool Connect(const std::string& ip, uint16_t port = DEFAULT_CONTROL_PORT, int timeout_ms = 3000);
    void Disconnect();
    bool IsConnected() const;

    std::string GetConnectedIp() const;
    uint16_t GetConnectedPort() const;

    // 发送 FastMirror 触控事件 (归一化 0~10000)
    bool SendTouch(uint8_t action, uint16_t norm_x, uint16_t norm_y, uint8_t pointer_id = 0);

    // 发送 FastMirror 物理与系统按键
    bool SendKey(uint16_t key_code, uint8_t action = 0);
    bool SendBack();
    bool SendHome();
    bool SendRecents();
    bool SendPing();

private:
    bool SendRawPacket(MessageType type, const uint8_t* payload, uint32_t payload_len);

    std::atomic<bool> is_connected_{false};
    std::string connected_ip_;
    uint16_t connected_port_{0};
    int socket_fd_{-1};
    std::mutex send_mutex_;
};

} // namespace fastmirror
} // namespace acast

