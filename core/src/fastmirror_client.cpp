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
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <cerrno>
#define CLOSE_SOCKET close
#define SHUTDOWN_SOCKET(s) shutdown(s, SHUT_RDWR)
#endif

namespace acast {
namespace fastmirror {

static void BindTcpSocketToMatchingInterface(int sock, const std::string& target_ip) {
#if defined(__APPLE__)
    struct in_addr target_addr;
    if (inet_pton(AF_INET, target_ip.c_str(), &target_addr) <= 0) return;
    uint32_t target_u32 = ntohl(target_addr.s_addr);
    if ((target_u32 & 0xFF000000) == 0x7F000000) return; // loopback

    struct ifaddrs* ifaddr = nullptr;
    if (getifaddrs(&ifaddr) == -1) return;

    unsigned int matched_if_index = 0;
    for (struct ifaddrs* ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_netmask || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
        std::string if_name = ifa->ifa_name ? ifa->ifa_name : "";
        if (if_name.find("utun") == 0 || if_name.find("ppp") == 0 || if_name.find("gif") == 0) continue;

        uint32_t addr_u32 = ntohl(((struct sockaddr_in*)ifa->ifa_addr)->sin_addr.s_addr);
        uint32_t mask_u32 = ntohl(((struct sockaddr_in*)ifa->ifa_netmask)->sin_addr.s_addr);
        if (mask_u32 != 0 && (addr_u32 & mask_u32) == (target_u32 & mask_u32)) {
            matched_if_index = if_nametoindex(ifa->ifa_name);
            if (matched_if_index > 0) break;
        }
    }
    freeifaddrs(ifaddr);

    if (matched_if_index > 0) {
        setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &matched_if_index, sizeof(matched_if_index));
    }
#else
    (void)sock;
    (void)target_ip;
#endif
}

FastMirrorClient::FastMirrorClient() {
#if defined(_WIN32)
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
}

FastMirrorClient::~FastMirrorClient() {
    StopReverseServer();
    Disconnect();
}

void FastMirrorClient::StartReverseServer(uint16_t listen_port, ReverseConnectCallback cb) {
    {
        std::lock_guard<std::mutex> lock(cb_mutex_);
        reverse_cb_ = std::move(cb);
    }
    std::lock_guard<std::mutex> lock(conn_mutex_);
    if (reverse_running_) return;
    reverse_running_ = true;
    reverse_server_thread_ = std::thread(&FastMirrorClient::ReverseServerLoop, this, listen_port);
}

void FastMirrorClient::StopReverseServer() {
    reverse_running_ = false;
    std::thread old_rev;
    {
        std::lock_guard<std::mutex> lock(conn_mutex_);
        if (reverse_server_fd_ >= 0) {
            SHUTDOWN_SOCKET(reverse_server_fd_);
            CLOSE_SOCKET(reverse_server_fd_);
            reverse_server_fd_ = -1;
        }
        old_rev = std::move(reverse_server_thread_);
    }
    if (old_rev.joinable()) {
        if (old_rev.get_id() == std::this_thread::get_id()) {
            old_rev.detach();
        } else {
            try {
                old_rev.join();
            } catch (...) {}
        }
    }
}

void FastMirrorClient::ReverseServerLoop(uint16_t listen_port) {
    int srv = (int)socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        reverse_running_ = false;
        return;
    }

    int reuse = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (const char*)&reuse, sizeof(reuse));
#ifdef SO_REUSEPORT
    setsockopt(srv, SOL_SOCKET, SO_REUSEPORT, (const char*)&reuse, sizeof(reuse));
#endif

    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(listen_port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) != 0 || listen(srv, 4) != 0) {
        CLOSE_SOCKET(srv);
        reverse_running_ = false;
        return;
    }

    reverse_server_fd_ = srv;

    while (reverse_running_) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_sock = (int)accept(srv, (struct sockaddr*)&client_addr, &client_len);
        if (client_sock < 0) {
            if (!reverse_running_) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }

        char ip_buf[64] = {0};
        inet_ntop(AF_INET, &client_addr.sin_addr, ip_buf, sizeof(ip_buf));
        std::string remote_ip(ip_buf);

        // 仅当控制端用户主动发起对该手机 IP 的连接（或收到手机主动点击直连请求）时，才接纳反向直连；
        // 拒绝后台静默自动重连，确保扫描到的手机只显示在列表中，由用户点击“连接手机”才建立连接。
        bool allow_adopt = false;
        {
            std::lock_guard<std::mutex> lock(conn_mutex_);
            if (!pending_connect_ip_.empty() && pending_connect_ip_ == remote_ip && !is_connected_) {
                allow_adopt = true;
            }
        }
        if (!allow_adopt) {
            CLOSE_SOCKET(client_sock);
            continue;
        }

        AdoptSocket(client_sock, remote_ip, listen_port);
    }

    if (reverse_server_fd_ >= 0) {
        CLOSE_SOCKET(reverse_server_fd_);
        reverse_server_fd_ = -1;
    }
}

void FastMirrorClient::AdoptSocket(int sock, const std::string& ip, uint16_t port) {
    int nodelay = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
    int keepalive = 1;
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, (const char*)&keepalive, sizeof(keepalive));
#ifdef SO_NOSIGPIPE
    int nosigpipe = 1;
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, (const char*)&nosigpipe, sizeof(nosigpipe));
#endif
#if defined(_WIN32)
    DWORD tv_send = 5000;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv_send, sizeof(tv_send));
#else
    struct timeval tv_send;
    tv_send.tv_sec = 5;
    tv_send.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv_send, sizeof(tv_send));
#endif

    std::thread old_hb;
    bool need_start_hb = false;
    {
        std::lock_guard<std::mutex> lock(conn_mutex_);
        pending_connect_ip_.clear();
        active_sockets_.push_back(sock);
        socket_fd_ = sock;
        connected_ip_ = ip;
        connected_port_ = port;
        bool was_connected = is_connected_.exchange(true);

        if (!was_connected || !heartbeat_thread_.joinable()) {
            stop_heartbeat_ = true;
            old_hb = std::move(heartbeat_thread_);
            need_start_hb = true;
        }
    }

    if (old_hb.joinable()) {
        if (old_hb.get_id() == std::this_thread::get_id()) {
            old_hb.detach();
        } else {
            try {
                old_hb.join();
            } catch (...) {}
        }
    }

    if (need_start_hb) {
        std::lock_guard<std::mutex> lock(conn_mutex_);
        if (is_connected_ && !heartbeat_thread_.joinable()) {
            stop_heartbeat_ = false;
            heartbeat_thread_ = std::thread(&FastMirrorClient::HeartbeatLoop, this);
        }
    }

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

    SendRawPacketToSocket(sock, MessageType::HANDSHAKE_REQ, reinterpret_cast<const uint8_t*>(&req), sizeof(req));

    std::thread(&FastMirrorClient::ReceiveSocketLoop, this, sock).detach();

    ReverseConnectCallback cb;
    {
        std::lock_guard<std::mutex> lock(cb_mutex_);
        cb = reverse_cb_;
    }
    if (cb) {
        cb(ip, port);
    }
}

static void SendUdpRadioWakeup(const std::string& target_ip) {
    int udp_sock = (int)socket(AF_INET, SOCK_DGRAM, 0);
    if (udp_sock < 0) return;

    BindTcpSocketToMatchingInterface(udp_sock, target_ip);

    struct sockaddr_in uaddr;
    std::memset(&uaddr, 0, sizeof(uaddr));
    uaddr.sin_family = AF_INET;
    uaddr.sin_port = htons(19998);
    if (inet_pton(AF_INET, target_ip.c_str(), &uaddr.sin_addr) > 0) {
        // 1. 发送 discover_phone 触发手机立即向外回传 UDP 信标，强制唤醒 iOS/Android 802.11 Wi-Fi PSM 休眠状态
        const char* wake_msg = "{\"cmd\":\"discover_phone\"}";
        sendto(udp_sock, wake_msg, (int)std::strlen(wake_msg), 0, (struct sockaddr*)&uaddr, sizeof(uaddr));

        // 2. 同时发送反向直连指令，通知支持反向直连的手机主动连入 19990
        const char* rev_msg = "{\"cmd\":\"request_reverse_connect\",\"tcp_port\":19990}";
        sendto(udp_sock, rev_msg, (int)std::strlen(rev_msg), 0, (struct sockaddr*)&uaddr, sizeof(uaddr));
    }
    CLOSE_SOCKET(udp_sock);
}

static int OpenNonBlockingCandidateSocket(const std::string& ip, const struct sockaddr_in& addr, bool& connected_immediately) {
    connected_immediately = false;
    int sock = (int)socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    // 绑定与目标 IP 同网段的物理/热点网卡（避免被 utun VPN 路由截获）
    BindTcpSocketToMatchingInterface(sock, ip);

    int nodelay = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));

    int keepalive = 1;
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, (const char*)&keepalive, sizeof(keepalive));
#ifdef SO_NOSIGPIPE
    int nosigpipe = 1;
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, (const char*)&nosigpipe, sizeof(nosigpipe));
#endif

#if defined(_WIN32)
    DWORD tv_send = 5000;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv_send, sizeof(tv_send));
    u_long nonblock = 1;
    ioctlsocket(sock, FIONBIO, &nonblock);
#else
    struct timeval tv_send;
    tv_send.tv_sec = 5;
    tv_send.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv_send, sizeof(tv_send));
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags >= 0) fcntl(sock, F_SETFL, flags | O_NONBLOCK);
#endif

    int rc = connect(sock, (const struct sockaddr*)&addr, sizeof(addr));
    if (rc == 0) {
        connected_immediately = true;
        return sock;
    }

#if defined(_WIN32)
    int err = WSAGetLastError();
    bool in_progress = (err == WSAEWOULDBLOCK || err == WSAEINPROGRESS);
#else
    bool in_progress = (errno == EINPROGRESS || errno == EWOULDBLOCK);
#endif
    if (!in_progress) {
        CLOSE_SOCKET(sock);
        return -1;
    }
    return sock;
}

static void RestoreSocketBlockingMode(int sock) {
#if defined(_WIN32)
    u_long block = 0;
    ioctlsocket(sock, FIONBIO, &block);
#else
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags >= 0) fcntl(sock, F_SETFL, flags & ~O_NONBLOCK);
#endif
}

bool FastMirrorClient::Connect(const std::string& ip, uint16_t port, int timeout_ms) {
    // 若该 IP 已经建立连接，直接复用返回成功
    {
        std::lock_guard<std::mutex> lock(conn_mutex_);
        if (is_connected_ && connected_ip_ == ip && !active_sockets_.empty()) {
            return true;
        }
    }

    uint64_t my_epoch = ++connect_epoch_;
    Disconnect();

    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) <= 0) {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(conn_mutex_);
        pending_connect_ip_ = ip;
    }

    // Happy Eyeballs 阶梯式并发 TCP SYN 探测 + UDP 射频唤醒：
    // 解决 macOS 热点 (bridge100) / 路由器下 iPhone 处于 802.11 PSM 节能休眠导致首包 SYN 被丢弃并陷入秒级退避的问题
    std::vector<int> candidates;
    int winner_sock = -1;
    int waited_ms = 0;
    const int step_ms = 25;
    const int spawn_interval_ms = 200;
    const size_t max_candidates = 8;
    int next_spawn_ms = 0;
    int max_wait = (timeout_ms > 0) ? timeout_ms : 5000;

    while (waited_ms < max_wait) {
        if (connect_epoch_.load() != my_epoch) {
            break;
        }
        if (is_connected_) {
            // 手机已通过反向直连端口 (19990) 成功连入
            for (int c : candidates) CLOSE_SOCKET(c);
            return true;
        }

        if (waited_ms >= next_spawn_ms && candidates.size() < max_candidates) {
            SendUdpRadioWakeup(ip);
            bool imm = false;
            int s = OpenNonBlockingCandidateSocket(ip, addr, imm);
            if (s >= 0) {
                if (imm) {
                    winner_sock = s;
                    break;
                }
                candidates.push_back(s);
            }
            next_spawn_ms = waited_ms + spawn_interval_ms;
        }

        if (candidates.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(step_ms));
            waited_ms += step_ms;
            continue;
        }

        fd_set wfds;
        FD_ZERO(&wfds);
        int max_fd = -1;
        for (int c : candidates) {
            FD_SET(c, &wfds);
            if (c > max_fd) max_fd = c;
        }

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = step_ms * 1000;
        int sel = select(max_fd + 1, nullptr, &wfds, nullptr, &tv);
        if (sel > 0) {
            for (size_t i = 0; i < candidates.size(); ) {
                int c = candidates[i];
                if (FD_ISSET(c, &wfds)) {
                    int so_err = 0;
                    socklen_t len = sizeof(so_err);
                    if (getsockopt(c, SOL_SOCKET, SO_ERROR, (char*)&so_err, &len) == 0 && so_err == 0) {
                        winner_sock = c;
                        candidates.erase(candidates.begin() + i);
                        break;
                    } else {
                        CLOSE_SOCKET(c);
                        candidates.erase(candidates.begin() + i);
                        continue;
                    }
                }
                ++i;
            }
            if (winner_sock >= 0) {
                break;
            }
        }
        waited_ms += step_ms;
    }

    for (int c : candidates) {
        CLOSE_SOCKET(c);
    }

    if (winner_sock < 0) {
        {
            std::lock_guard<std::mutex> lock(conn_mutex_);
            if (connect_epoch_.load() == my_epoch) {
                pending_connect_ip_.clear();
            }
        }
        return is_connected_.load();
    }

    RestoreSocketBlockingMode(winner_sock);
    AdoptSocket(winner_sock, ip, port);
    return true;
}

void FastMirrorClient::Disconnect() {
    std::vector<int> to_shutdown;
    std::thread old_hb;
    {
        std::lock_guard<std::mutex> lock(conn_mutex_);
        pending_connect_ip_.clear();
        is_connected_ = false;
        stop_heartbeat_ = true;
        socket_fd_ = -1;
        to_shutdown.swap(active_sockets_);
        connected_ip_.clear();
        connected_port_ = 0;
        old_hb = std::move(heartbeat_thread_);
    }
    for (int s : to_shutdown) {
        if (s >= 0) {
            // 仅执行 shutdown 唤醒阻塞中的 recv()，由 ReceiveSocketLoop 安全退出后关闭 fd，防止并发 fd 复用冲突
            SHUTDOWN_SOCKET(s);
        }
    }
    if (old_hb.joinable()) {
        if (old_hb.get_id() == std::this_thread::get_id()) {
            old_hb.detach();
        } else {
            try {
                old_hb.join();
            } catch (...) {}
        }
    }
}

bool FastMirrorClient::IsConnected() const {
    return is_connected_;
}

std::string FastMirrorClient::GetConnectedIp() const {
    std::lock_guard<std::mutex> lock(conn_mutex_);
    return connected_ip_;
}

uint16_t FastMirrorClient::GetConnectedPort() const {
    std::lock_guard<std::mutex> lock(conn_mutex_);
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

void FastMirrorClient::SetCameraCallback(VideoFrameCallback cb) {
    std::lock_guard<std::mutex> lock(cb_mutex_);
    camera_cb_ = std::move(cb);
}

bool FastMirrorClient::SendRawPacketToSocket(int sock, MessageType type, const uint8_t* payload, uint32_t payload_len) {
    if (sock < 0) return false;
    std::vector<uint8_t> packet = ProtocolCodec::Pack(type, payload, payload_len);

    std::lock_guard<std::mutex> lock(send_mutex_);
    if (sock < 0) return false;

    int total = (int)packet.size();
    int total_sent = 0;
    while (total_sent < total) {
        int sent = (int)send(sock, reinterpret_cast<const char*>(packet.data() + total_sent), total - total_sent, 0);
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
            return false;
        }
        total_sent += sent;
    }
    return true;
}

bool FastMirrorClient::SendRawPacket(MessageType type, const uint8_t* payload, uint32_t payload_len) {
    if (!is_connected_ || socket_fd_ < 0) return false;
    return SendRawPacketToSocket(socket_fd_, type, payload, payload_len);
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
        for (int i = 0; i < 500; ++i) { // 10秒定时器 (20ms 步进，确保 Disconnect 瞬間退出无卡顿)
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            if (!is_connected_ || stop_heartbeat_) return;
        }
        if (!is_connected_ || stop_heartbeat_) break;
        SendPing();
    }
}

void FastMirrorClient::ReceiveSocketLoop(int sock) {
    uint8_t header_buf[16];
    size_t recvd = 0;

    while (is_connected_ && sock >= 0) {
        // 读取 16 字节头部
        bool read_ok = true;
        while (recvd < 16) {
            int n = recv(sock, reinterpret_cast<char*>(header_buf + recvd), 16 - recvd, 0);
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
                int n = recv(sock, reinterpret_cast<char*>(payload.data() + p_recvd), payload_len - p_recvd, 0);
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
        } else if (msg_type == static_cast<uint8_t>(MessageType::CAMERA_FRAME)) {
            bool is_key = false;
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
                cb = camera_cb_;
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
            SendRawPacketToSocket(sock, MessageType::PONG, nullptr, 0);
        } else if (msg_type == static_cast<uint8_t>(MessageType::PONG)) {
            // 心跳保活回复确认
        }
    }

    // 清理当前断开的 socket，若仍存在其他活跃 socket（如主应用与广播扩展并存），则无缝保持连接状态
    {
        std::lock_guard<std::mutex> lock(conn_mutex_);
        auto it = std::find(active_sockets_.begin(), active_sockets_.end(), sock);
        if (it != active_sockets_.end()) {
            active_sockets_.erase(it);
        }
        if (active_sockets_.empty()) {
            socket_fd_ = -1;
            is_connected_ = false;
        } else if (socket_fd_ == sock) {
            socket_fd_ = active_sockets_.back();
        }
    }
    if (sock >= 0) {
        CLOSE_SOCKET(sock);
    }
}

} // namespace fastmirror
} // namespace acast
