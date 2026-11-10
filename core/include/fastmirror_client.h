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
using ReverseConnectCallback = std::function<void(const std::string& remote_ip, uint16_t remote_port)>;

class FastMirrorClient {
public:
    FastMirrorClient();
    ~FastMirrorClient();

    // 建立局域网 Wi-Fi IP 或本机端口连接
    bool Connect(const std::string& ip, uint16_t port = DEFAULT_CONTROL_PORT, int timeout_ms = 3000);
    void Disconnect();
    bool IsConnected() const;

    // 启动桌面端反向直连 TCP 监听服务 (默认 19990，供 iOS/Android 主动向外直连桌面端，绕过 iOS 入站端口冻结/防火墙限制)
    void StartReverseServer(uint16_t listen_port = 19990, ReverseConnectCallback cb = nullptr);
    void StopReverseServer();
    void AdoptSocket(int sock, const std::string& ip, uint16_t port);

    std::string GetConnectedIp() const;
    uint16_t GetConnectedPort() const;

    // 视频与音频数据接收回调
    void SetVideoCallback(VideoFrameCallback cb);
    void SetAudioCallback(AudioFrameCallback cb);
    void SetCameraCallback(VideoFrameCallback cb);

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
    bool SendRawPacketToSocket(int sock, MessageType type, const uint8_t* payload, uint32_t payload_len);
    void ReceiveSocketLoop(int sock);
    void HeartbeatLoop();

    std::atomic<bool> is_connected_{false};
    std::string connected_ip_;
    uint16_t connected_port_{0};
    int socket_fd_{-1};
    std::vector<int> active_sockets_;
    std::mutex send_mutex_;

    std::thread heartbeat_thread_;
    std::atomic<bool> stop_heartbeat_{false};

    std::mutex cb_mutex_;
    VideoFrameCallback video_cb_;
    AudioFrameCallback audio_cb_;
    VideoFrameCallback camera_cb_;
    ReverseConnectCallback reverse_cb_;

    std::mutex conn_mutex_;
    std::atomic<bool> reverse_running_{false};
    int reverse_server_fd_{-1};
    std::thread reverse_server_thread_;
    void ReverseServerLoop(uint16_t listen_port);
};

} // namespace fastmirror
} // namespace acast
