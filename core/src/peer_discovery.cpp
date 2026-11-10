#include "peer_discovery.h"
#include <iostream>
#include <sstream>
#include <cstring>
#include <algorithm>

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using socket_t = SOCKET;
#define IS_VALID_SOCKET(s) ((s) != INVALID_SOCKET)
#define CLOSE_SOCKET(s) closesocket(s)
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <netdb.h>
#include <ifaddrs.h>
#include <net/if.h>
using socket_t = int;
#define IS_VALID_SOCKET(s) ((s) >= 0)
#define CLOSE_SOCKET(s) close(s)
#endif

namespace acast {
namespace discovery {

static void InitSockets() {
#if defined(_WIN32)
    static bool initialized = false;
    if (!initialized) {
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
        initialized = true;
    }
#endif
}

static std::string GetSystemHostName() {
    char hostname[256] = {0};
#if defined(_WIN32)
    DWORD size = sizeof(hostname);
    if (GetComputerNameA(hostname, &size)) {
        return std::string(hostname);
    }
#else
    if (gethostname(hostname, sizeof(hostname)) == 0) {
        return std::string(hostname);
    }
#endif
    return "Desktop-PC";
}

static std::string ExtractJsonField(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\":";
    size_t pos = json.find(search);
    if (pos == std::string::npos) return "";
    pos += search.length();
    while (pos < json.length() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\"')) {
        pos++;
    }
    size_t end = json.find_first_of("\",}\r\n", pos);
    if (end == std::string::npos) end = json.length();
    return json.substr(pos, end - pos);
}

PeerDiscovery& PeerDiscovery::GetInstance() {
    static PeerDiscovery instance;
    return instance;
}

PeerDiscovery::PeerDiscovery() {
    InitSockets();
}

PeerDiscovery::~PeerDiscovery() {
    Stop();
}

void PeerDiscovery::Start(const std::string& desktop_name) {
    if (is_running_) return;

    desktop_name_ = desktop_name.empty() ? GetSystemHostName() : desktop_name;
    is_running_ = true;

    worker_thread_ = std::make_unique<std::thread>(&PeerDiscovery::DiscoveryLoop, this);
}

void PeerDiscovery::Stop() {
    if (!is_running_) return;
    is_running_ = false;

    if (socket_fd_ >= 0) {
        CLOSE_SOCKET((socket_t)socket_fd_);
        socket_fd_ = -1;
    }

    if (worker_thread_ && worker_thread_->joinable()) {
        worker_thread_->join();
    }
    worker_thread_.reset();

    std::lock_guard<std::mutex> lock(mutex_);
    phones_.clear();
}

void PeerDiscovery::SetPhoneListCallback(PhoneListCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    phone_cb_ = std::move(cb);
}

void PeerDiscovery::SetConnectRequestCallback(ConnectRequestCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    connect_req_cb_ = std::move(cb);
}

std::vector<DiscoveredPhone> PeerDiscovery::GetDiscoveredPhones() {
    std::lock_guard<std::mutex> lock(mutex_);
    return phones_;
}

void PeerDiscovery::SearchPhones() {
    if (!is_running_) return;
    std::string searchMsg = "{\"cmd\":\"discover_phone\"}";
    SendBroadcast(searchMsg);
}

static void SendUnicastUdp(const std::string& json_str, const std::string& target_ip, uint16_t port) {
    if (target_ip.empty()) return;
    socket_t sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (!IS_VALID_SOCKET(sock)) return;

    struct sockaddr_in destAddr;
    std::memset(&destAddr, 0, sizeof(destAddr));
    destAddr.sin_family = AF_INET;
    destAddr.sin_port = htons(port);
    if (inet_pton(AF_INET, target_ip.c_str(), &destAddr.sin_addr) > 0) {
        sendto(sock, json_str.c_str(), (int)json_str.length(), 0, (struct sockaddr*)&destAddr, sizeof(destAddr));
    }
    CLOSE_SOCKET(sock);
}

void PeerDiscovery::SendBroadcast(const std::string& json_str) {
    socket_t sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (!IS_VALID_SOCKET(sock)) return;

    int broadcast = 1;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, (const char*)&broadcast, sizeof(broadcast));

    struct sockaddr_in bcastAddr;
    std::memset(&bcastAddr, 0, sizeof(bcastAddr));
    bcastAddr.sin_family = AF_INET;
    bcastAddr.sin_port = htons(DISCOVERY_UDP_PORT);
    bcastAddr.sin_addr.s_addr = htonl(INADDR_BROADCAST);

    sendto(sock, json_str.c_str(), (int)json_str.length(), 0, (struct sockaddr*)&bcastAddr, sizeof(bcastAddr));

#if !defined(_WIN32)
    // 同时向所有活动网卡的定向子网广播地址 (如 192.168.x.255) 发送，彻底解决 iOS 与 macOS 路由表拦截受限广播 (255.255.255.255) 的问题
    struct ifaddrs* ifap = nullptr;
    if (getifaddrs(&ifap) == 0 && ifap) {
        for (struct ifaddrs* ifa = ifap; ifa != nullptr; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if ((ifa->ifa_flags & IFF_UP) == 0 || (ifa->ifa_flags & IFF_LOOPBACK) != 0) continue;

            struct sockaddr_in* sinAddr = (struct sockaddr_in*)ifa->ifa_addr;
            uint32_t ipHost = ntohl(sinAddr->sin_addr.s_addr);
            if (ipHost == 0 || (ipHost >> 24) == 127) continue;

            uint32_t bcastNet = htonl(INADDR_BROADCAST);
            if ((ifa->ifa_flags & IFF_BROADCAST) && ifa->ifa_broadaddr && ifa->ifa_broadaddr->sa_family == AF_INET) {
                bcastNet = ((struct sockaddr_in*)ifa->ifa_broadaddr)->sin_addr.s_addr;
            } else if (ifa->ifa_netmask && ifa->ifa_netmask->sa_family == AF_INET) {
                uint32_t maskNet = ((struct sockaddr_in*)ifa->ifa_netmask)->sin_addr.s_addr;
                bcastNet = (sinAddr->sin_addr.s_addr & maskNet) | (~maskNet);
            }

            if (bcastNet != htonl(INADDR_BROADCAST) && bcastNet != 0) {
                struct sockaddr_in subBcast;
                std::memset(&subBcast, 0, sizeof(subBcast));
                subBcast.sin_family = AF_INET;
                subBcast.sin_port = htons(DISCOVERY_UDP_PORT);
                subBcast.sin_addr.s_addr = bcastNet;
                sendto(sock, json_str.c_str(), (int)json_str.length(), 0, (struct sockaddr*)&subBcast, sizeof(subBcast));
            }
        }
        freeifaddrs(ifap);
    }
#endif

    CLOSE_SOCKET(sock);
}

void PeerDiscovery::BroadcastDesktopBeacon() {
    std::string osName = "macOS";
#if defined(_WIN32)
    osName = "Windows";
#endif
    std::string beacon = "{\"cmd\":\"desktop_beacon\",\"device_name\":\"" + desktop_name_ +
                         "\",\"port\":" + std::to_string(DISCOVERY_UDP_PORT) +
                         ",\"os\":\"" + osName + "\"}";
    SendBroadcast(beacon);
}

void PeerDiscovery::PruneExpiredPhones() {
    auto now = std::chrono::steady_clock::now();
    bool changed = false;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = std::remove_if(phones_.begin(), phones_.end(), [&](const DiscoveredPhone& p) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - p.last_seen).count();
            return elapsed > 6; // 超过 6 秒无心跳视为下线
        });
        if (it != phones_.end()) {
            phones_.erase(it, phones_.end());
            changed = true;
        }
    }

    if (changed) {
        PhoneListCallback cb;
        std::vector<DiscoveredPhone> currentList;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            cb = phone_cb_;
            currentList = phones_;
        }
        if (cb) {
            cb(currentList);
        }
    }
}

void PeerDiscovery::DiscoveryLoop() {
    socket_t sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (!IS_VALID_SOCKET(sock)) {
        is_running_ = false;
        return;
    }
    socket_fd_ = (int)sock;

    int reuse = 1;
#if defined(SO_REUSEADDR)
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (const char*)&reuse, sizeof(reuse));
#endif
#if defined(SO_REUSEPORT)
    setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, (const char*)&reuse, sizeof(reuse));
#endif

    int broadcast = 1;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, (const char*)&broadcast, sizeof(broadcast));

#if defined(_WIN32)
    DWORD timeout = 1000;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout, sizeof(timeout));
#else
    struct timeval tv;
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#endif

    struct sockaddr_in bindAddr;
    std::memset(&bindAddr, 0, sizeof(bindAddr));
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_port = htons(DISCOVERY_UDP_PORT);
    bindAddr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(sock, (struct sockaddr*)&bindAddr, sizeof(bindAddr)) < 0) {
        CLOSE_SOCKET(sock);
        socket_fd_ = -1;
        is_running_ = false;
        return;
    }

    // 启动即刻宣告一次电脑控制端存在
    BroadcastDesktopBeacon();
    SearchPhones();

    auto lastBeaconTime = std::chrono::steady_clock::now();
    char buffer[2048];

    while (is_running_) {
        struct sockaddr_in remoteAddr;
        socklen_t addrLen = sizeof(remoteAddr);

        int bytes = recvfrom(sock, buffer, sizeof(buffer) - 1, 0, (struct sockaddr*)&remoteAddr, &addrLen);
        if (bytes > 0) {
            buffer[bytes] = '\0';
            char ipStr[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &(remoteAddr.sin_addr), ipStr, INET_ADDRSTRLEN);
            HandlePacket(std::string(buffer, bytes), std::string(ipStr));
        }

        auto now = std::chrono::steady_clock::now();
        // 每 2 秒广播一次保活
        if (std::chrono::duration_cast<std::chrono::seconds>(now - lastBeaconTime).count() >= 2) {
            BroadcastDesktopBeacon();
            lastBeaconTime = now;
            PruneExpiredPhones();
        }
    }

    CLOSE_SOCKET(sock);
    socket_fd_ = -1;
}

void PeerDiscovery::HandlePacket(const std::string& msg, const std::string& remote_ip) {
    std::string cmd = ExtractJsonField(msg, "cmd");
    if (cmd.empty()) return;

    if (cmd == "phone_beacon") {
        std::string name = ExtractJsonField(msg, "device_name");
        std::string ip = ExtractJsonField(msg, "ip");
        std::string portStr = ExtractJsonField(msg, "port");
        std::string model = ExtractJsonField(msg, "model");

        if (ip.empty() || ip == "127.0.0.1") {
            ip = remote_ip;
        }
        if (name.empty()) {
            name = model.empty() ? ("Android Phone (" + ip + ")") : model;
        }
        uint16_t port = 19999;
        try {
            if (!portStr.empty()) port = (uint16_t)std::stoi(portStr);
        } catch (...) {}

        bool changed = false;
        std::vector<DiscoveredPhone> currentList;
        PhoneListCallback cb;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = std::find_if(phones_.begin(), phones_.end(), [&](const DiscoveredPhone& p) {
                return p.ip == ip;
            });
            if (it != phones_.end()) {
                it->name = name;
                it->port = port;
                it->model = model;
                it->last_seen = std::chrono::steady_clock::now();
            } else {
                DiscoveredPhone phone;
                phone.device_id = "phone_" + ip;
                phone.name = name;
                phone.ip = ip;
                phone.port = port;
                phone.model = model;
                phone.last_seen = std::chrono::steady_clock::now();
                phones_.push_back(phone);
                changed = true;
            }
            cb = phone_cb_;
            currentList = phones_;
        }

        if (changed && cb) {
            cb(currentList);
        }

        // 收到手机广播后，同时单播回送一次电脑端信标，确保 iOS 在开启广播过滤的路由器下也能立即发现电脑
        std::string osName = "macOS";
#if defined(_WIN32)
        osName = "Windows";
#endif
        std::string beacon = "{\"cmd\":\"desktop_beacon\",\"device_name\":\"" + desktop_name_ +
                             "\",\"port\":" + std::to_string(DISCOVERY_UDP_PORT) +
                             ",\"os\":\"" + osName + "\"}";
        SendUnicastUdp(beacon, ip, DISCOVERY_UDP_PORT);
    } else if (cmd == "discover_desktop") {
        // 手机主动探测电脑控制端，立即广播并单播宣告自身
        BroadcastDesktopBeacon();
        std::string osName = "macOS";
#if defined(_WIN32)
        osName = "Windows";
#endif
        std::string beacon = "{\"cmd\":\"desktop_beacon\",\"device_name\":\"" + desktop_name_ +
                             "\",\"port\":" + std::to_string(DISCOVERY_UDP_PORT) +
                             ",\"os\":\"" + osName + "\"}";
        SendUnicastUdp(beacon, remote_ip, DISCOVERY_UDP_PORT);
    } else if (cmd == "connect_request") {
        // 手机在屏幕上直接点击了本电脑控制端，主动通知直连
        std::string phoneName = ExtractJsonField(msg, "phone_name");
        std::string phoneIp = ExtractJsonField(msg, "phone_ip");
        std::string portStr = ExtractJsonField(msg, "phone_port");
        if (phoneIp.empty()) phoneIp = remote_ip;
        uint16_t phonePort = 19999;
        try {
            if (!portStr.empty()) phonePort = (uint16_t)std::stoi(portStr);
        } catch (...) {}

        ConnectRequest req;
        req.phone_name = phoneName.empty() ? ("Android (" + phoneIp + ")") : phoneName;
        req.phone_ip = phoneIp;
        req.phone_port = phonePort;

        ConnectRequestCallback cb;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            cb = connect_req_cb_;
        }
        if (cb) {
            cb(req);
        }
    }
}

} // namespace discovery
} // namespace acast

