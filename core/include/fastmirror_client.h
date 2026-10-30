#pragma once

#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <cstdint>
#include <functional>
#include <thread>
#include "fastmirror_protocol.h"

namespace acast {
namespace fastmirror {

using VideoFrameCallback = std::function<void(const uint8_t* data, size_t size, bool is_key, int64_t pts_us)>;
using AudioFrameCallback = std::function<void(const uint8_t* data, size_t size)>;

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

    // 视频与音频数据接收回调
    void SetVideoCallback(VideoFrameCallback cb);
    void SetAudioCallback(AudioFrameCallback cb);

    // 发送 FastMirror 触控事件 (归一化 0~10000)
    bool SendTouch(uint8_t action, uint16_t norm_x, uint16_t norm_y, uint8_t pointer_id = 0);

    // 发送 FastMirror 键盘文本与物理系统按键
    bool SendTextInput(const std::string& text);
    bool SendKey(uint16_t key_code, uint8_t action = 0);
    bool SendBack();
    bool SendHome();
    bool SendRecents();
    bool SendPing();

private:
    bool SendRawPacket(MessageType type, const uint8_t* payload, uint32_t payload_len);
    void ReceiveLoop();

    std::atomic<bool> is_connected_{false};
    std::string connected_ip_;
    uint16_t connected_port_{0};
    int socket_fd_{-1};
    std::mutex send_mutex_;

    std::thread recv_thread_;
    std::mutex cb_mutex_;
    VideoFrameCallback video_cb_;
    AudioFrameCallback audio_cb_;
};

} // namespace fastmirror
} // namespace acast
