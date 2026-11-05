#include "fastmirror_client.h"
#include <iostream>
#include <cstring>
#include <chrono>
#include <algorithm>

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
typedef int socklen_t;
#define CLOSE_SOCKET closesocket
#define SHUTDOWN_SOCKET(s) shutdown(s, SD_BOTH)
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#define CLOSE_SOCKET close
#define SHUTDOWN_SOCKET(s) shutdown(s, SHUT_RDWR)
#endif

namespace acast {
namespace fastmirror {

FastMirrorClient::FastMirrorClient() {
#if defined(_WIN32)
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
}

FastMirrorClient::~FastMirrorClient() {
    Disconnect();
}

bool FastMirrorClient::Connect(const std::string& ip, uint16_t port, int timeout_ms) {
    Disconnect();

    int sock = (int)socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return false;

    // 设置 TCP_NODELAY 降低延迟 (<20ms)
    int nodelay = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));

    // 启用 TCP 保活，保持长连接不被路由器或系统中断
    int keepalive = 1;
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, (const char*)&keepalive, sizeof(keepalive));

    // 设置合理的发送超时（防止网络彻底拥死时无限阻塞）
#if defined(_WIN32)
    DWORD tv_send = 5000;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv_send, sizeof(tv_send));
#else
    struct timeval tv_send;
    tv_send.tv_sec = 5;
    tv_send.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv_send, sizeof(tv_send));
#endif

    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) <= 0) {
        CLOSE_SOCKET(sock);
        return false;
    }

    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        CLOSE_SOCKET(sock);
        return false;
    }

    socket_fd_ = sock;
    connected_ip_ = ip;
    connected_port_ = port;
    is_connected_ = true;
    stop_heartbeat_ = false;

    // 握手包发送
    HandshakeReqPayload req;
    req.client_version = 0x0201;
#if defined(_WIN32)
    req.platform = 1;
#elif defined(__APPLE__)
    req.platform = 2;
#else
    req.platform = 0;
#endif
    std::string client_name = "ACast-Desktop-Controller";
    req.device_name_len = (uint8_t)std::min<size_t>(client_name.length(), 63);
    std::memset(req.device_name, 0, sizeof(req.device_name));
    std::memcpy(req.device_name, client_name.c_str(), req.device_name_len);

    SendRawPacket(MessageType::HANDSHAKE_REQ, reinterpret_cast<const uint8_t*>(&req), sizeof(req));

    // 启动持续接收后台线程与定期心跳保活线程
    recv_thread_ = std::thread(&FastMirrorClient::ReceiveLoop, this);
    heartbeat_thread_ = std::thread(&FastMirrorClient::HeartbeatLoop, this);

    return true;
}

void FastMirrorClient::Disconnect() {
    is_connected_ = false;
    stop_heartbeat_ = true;
    if (socket_fd_ >= 0) {
        SHUTDOWN_SOCKET(socket_fd_);
        CLOSE_SOCKET(socket_fd_);
        socket_fd_ = -1;
    }
    if (recv_thread_.joinable()) {
        recv_thread_.join();
    }
    if (heartbeat_thread_.joinable()) {
        heartbeat_thread_.join();
    }
    connected_ip_.clear();
    connected_port_ = 0;
}

bool FastMirrorClient::IsConnected() const {
    return is_connected_;
}

std::string FastMirrorClient::GetConnectedIp() const {
    return connected_ip_;
}

uint16_t FastMirrorClient::GetConnectedPort() const {
    return connected_port_;
}

void FastMirrorClient::SetVideoCallback(VideoFrameCallback cb) {
    std::lock_guard<std::mutex> lock(cb_mutex_);
    video_cb_ = std::move(cb);
}

void FastMirrorClient::SetAudioCallback(AudioFrameCallback cb) {
    std::lock_guard<std::mutex> lock(cb_mutex_);
    audio_cb_ = std::move(cb);
}

bool FastMirrorClient::SendRawPacket(MessageType type, const uint8_t* payload, uint32_t payload_len) {
    if (!is_connected_ || socket_fd_ < 0) return false;
    std::vector<uint8_t> packet = ProtocolCodec::Pack(type, payload, payload_len);

    std::lock_guard<std::mutex> lock(send_mutex_);
    if (!is_connected_ || socket_fd_ < 0) return false;

    int total = (int)packet.size();
    int total_sent = 0;
    while (total_sent < total) {
        int sent = (int)send(socket_fd_, reinterpret_cast<const char*>(packet.data() + total_sent), total - total_sent, 0);
        if (sent <= 0) {
            if (sent < 0) {
#if defined(_WIN32)
                int err = WSAGetLastError();
                if (err == WSAEWOULDBLOCK || err == WSAEINTR) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(2));
                    continue;
                }
#else
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(2));
                    continue;
                }
#endif
            }
            Disconnect();
            return false;
        }
        total_sent += sent;
    }
    return true;
}

bool FastMirrorClient::SendTouch(uint8_t action, uint16_t norm_x, uint16_t norm_y, uint8_t pointer_id) {
    TouchPayload p;
    p.pointer_id = pointer_id;
    p.x = htons(norm_x);
    p.y = htons(norm_y);
    p.pressure = htons(1000);

    MessageType type = MessageType::TOUCH_DOWN;
    if (action == 1) type = MessageType::TOUCH_MOVE;
    else if (action == 2) type = MessageType::TOUCH_UP;
    else if (action == 3) type = MessageType::TOUCH_CANCEL;

    return SendRawPacket(type, reinterpret_cast<const uint8_t*>(&p), sizeof(p));
}

bool FastMirrorClient::SendTextInput(const std::string& text) {
    if (text.empty()) return true;
    return SendRawPacket(MessageType::TEXT_INPUT, reinterpret_cast<const uint8_t*>(text.data()), (uint32_t)text.size());
}

bool FastMirrorClient::SendKey(uint16_t key_code, uint8_t action) {
    KeyPayload p;
    p.key_code = htons(key_code);
    p.action = action;
    return SendRawPacket(MessageType::KEY_DOWN, reinterpret_cast<const uint8_t*>(&p), sizeof(p));
}

bool FastMirrorClient::SendBack() {
    return SendKey(static_cast<uint16_t>(SystemKeyCode::KEY_BACK), 0);
}

bool FastMirrorClient::SendHome() {
    return SendKey(static_cast<uint16_t>(SystemKeyCode::KEY_HOME), 0);
}

bool FastMirrorClient::SendRecents() {
    return SendKey(static_cast<uint16_t>(SystemKeyCode::KEY_APP_SWITCH), 0);
}

bool FastMirrorClient::SendPing() {
    return SendRawPacket(MessageType::PING, nullptr, 0);
}

void FastMirrorClient::HeartbeatLoop() {
    while (is_connected_ && !stop_heartbeat_) {
        for (int i = 0; i < 100; ++i) { // 10秒定时器
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            if (!is_connected_ || stop_heartbeat_) return;
        }
        if (!is_connected_ || stop_heartbeat_) break;
        SendPing();
    }
}

void FastMirrorClient::ReceiveLoop() {
    uint8_t header_buf[16];
    size_t recvd = 0;

    while (is_connected_ && socket_fd_ >= 0) {
        // 读取 16 字节头部
        bool read_ok = true;
        while (recvd < 16) {
            int n = recv(socket_fd_, reinterpret_cast<char*>(header_buf + recvd), 16 - recvd, 0);
            if (n <= 0) {
                if (n < 0) {
#if defined(_WIN32)
                    int err = WSAGetLastError();
                    if (err == WSAEWOULDBLOCK || err == WSAEINTR || err == WSAETIMEDOUT) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(5));
                        continue;
                    }
#else
                    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(5));
                        continue;
                    }
#endif
                }
                read_ok = false;
                break;
            }
            recvd += n;
        }
        if (!read_ok || !is_connected_) break;

        uint16_t magic = (static_cast<uint16_t>(header_buf[0]) << 8) | header_buf[1];
        if (magic != MAGIC_NUMBER && magic != 0x464D && magic != 0x4D46) {
            // 滑动窗口探测：后移 1 字节并继续读取 1 字节匹配魔数，杜绝帧边界丢失错位
            std::memmove(header_buf, header_buf + 1, 15);
            recvd = 15;
            continue;
        }
        recvd = 0; // 成功匹配魔数，头部完整消耗

        uint8_t msg_type = header_buf[2];
        uint32_t payload_len = (static_cast<uint32_t>(header_buf[4]) << 24) |
                               (static_cast<uint32_t>(header_buf[5]) << 16) |
                               (static_cast<uint32_t>(header_buf[6]) << 8)  |
                               (static_cast<uint32_t>(header_buf[7]));
        int64_t pts_us = 0;
        for (int i = 0; i < 8; ++i) {
            pts_us = (pts_us << 8) | header_buf[8 + i];
        }

        if (payload_len > 10 * 1024 * 1024) {
            // 异常超大包保护：说明头字节发生伪魔数错位，滑动 1 字节寻找下一个魔数重同步，绝不断开连接
            std::memmove(header_buf, header_buf + 1, 15);
            recvd = 15;
            continue;
        }

        std::vector<uint8_t> payload;
        if (payload_len > 0) {
            payload.resize(payload_len);
            size_t p_recvd = 0;
            while (p_recvd < payload_len) {
                int n = recv(socket_fd_, reinterpret_cast<char*>(payload.data() + p_recvd), payload_len - p_recvd, 0);
                if (n <= 0) {
                    if (n < 0) {
#if defined(_WIN32)
                        int err = WSAGetLastError();
                        if (err == WSAEWOULDBLOCK || err == WSAEINTR || err == WSAETIMEDOUT) {
                            std::this_thread::sleep_for(std::chrono::milliseconds(5));
                            continue;
                        }
#else
                        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                            std::this_thread::sleep_for(std::chrono::milliseconds(5));
                            continue;
                        }
#endif
                    }
                    read_ok = false;
                    break;
                }
                p_recvd += n;
            }
            if (!read_ok || !is_connected_) break;
        }

        // 处理接收到的消息包
        if (msg_type == static_cast<uint8_t>(MessageType::VIDEO_FRAME)) {
            bool is_key = false;
            // 扫描判断是否含有关键帧 SPS(7) 或 IDR(5)
            for (size_t i = 0; i + 4 < payload.size(); ++i) {
                if (payload[i] == 0 && payload[i+1] == 0 &&
                    ((payload[i+2] == 1 && ((payload[i+3] & 0x1F) == 5 || (payload[i+3] & 0x1F) == 7)) ||
                     (payload[i+2] == 0 && payload[i+3] == 1 && ((payload[i+4] & 0x1F) == 5 || (payload[i+4] & 0x1F) == 7)))) {
                    is_key = true;
                    break;
                }
            }

            VideoFrameCallback cb;
            {
                std::lock_guard<std::mutex> lock(cb_mutex_);
                cb = video_cb_;
            }
            if (cb) {
                cb(payload.data(), payload.size(), is_key, pts_us);
            }
        } else if (msg_type == static_cast<uint8_t>(MessageType::AUDIO_FRAME)) {
            AudioFrameCallback cb;
            {
                std::lock_guard<std::mutex> lock(cb_mutex_);
                cb = audio_cb_;
            }
            if (cb) {
                cb(payload.data(), payload.size());
            }
        } else if (msg_type == static_cast<uint8_t>(MessageType::PING)) {
            SendRawPacket(MessageType::PONG, nullptr, 0);
        } else if (msg_type == static_cast<uint8_t>(MessageType::PONG)) {
            // 心跳保活回复确认
        }
    }
    is_connected_ = false;
}

} // namespace fastmirror
} // namespace acast
