#include "http_ts_server.h"
#include <cstring>
#include <iostream>
#include <vector>

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_t = SOCKET;
#define IS_VALID_SOCKET(s) ((s) != INVALID_SOCKET)
#define CLOSE_SOCKET(s) closesocket(s)
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
using socket_t = int;
#define IS_VALID_SOCKET(s) ((s) >= 0)
#define CLOSE_SOCKET(s) close(s)
#endif

namespace acast {
namespace media {

// 标准 TS 包长 188 字节，同步字节 0x47
constexpr uint8_t TS_SYNC_BYTE = 0x47;
constexpr uint16_t TS_PID_PAT = 0x0000;
constexpr uint16_t TS_PID_PMT = 0x1000;
constexpr uint16_t TS_PID_VIDEO = 0x0100;
constexpr uint16_t TS_PID_AUDIO = 0x0101;

HttpTsServer::HttpTsServer(int port) : port_(port) {}

HttpTsServer::~HttpTsServer() {
    Stop();
}

std::string HttpTsServer::GetStreamUrl(const std::string& local_ip) const {
    return "http://" + local_ip + ":" + std::to_string(port_) + "/live.ts";
}

bool HttpTsServer::Start() {
    if (is_running_) return true;
    is_running_ = true;
    server_thread_ = std::make_unique<std::thread>(&HttpTsServer::RunServer, this);
    return true;
}

void HttpTsServer::Stop() {
    is_running_ = false;
    queue_cv_.notify_all();
    if (server_thread_ && server_thread_->joinable()) {
        server_thread_->join();
    }
}

void HttpTsServer::RunServer() {
    socket_t server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (!IS_VALID_SOCKET(server_fd)) return;

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));

    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port_);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        CLOSE_SOCKET(server_fd);
        return;
    }

    listen(server_fd, 5);

    while (is_running_) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        socket_t client_sock = accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
        if (!IS_VALID_SOCKET(client_sock)) continue;

        // 简易单/多客户端推流处理
        std::thread([this, client_sock]() {
            char req[1024];
            int n = recv(client_sock, req, sizeof(req) - 1, 0);
            if (n <= 0) {
                CLOSE_SOCKET(client_sock);
                return;
            }

            // 发送实时流 HTTP 响应头
            const char* http_header =
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: video/mp2t\r\n"
                "Connection: close\r\n"
                "Access-Control-Allow-Origin: *\r\n"
                "\r\n";
            send(client_sock, http_header, (int)std::strlen(http_header), 0);

            // 首先发送初始 PAT 与 PMT
            auto pat = GeneratePat();
            auto pmt = GeneratePmt();
            send(client_sock, (const char*)pat.data(), (int)pat.size(), 0);
            send(client_sock, (const char*)pmt.data(), (int)pmt.size(), 0);

            while (is_running_) {
                std::vector<uint8_t> data;
                {
                    std::unique_lock<std::mutex> lock(queue_mutex_);
                    queue_cv_.wait(lock, [this]() {
                        return !is_running_ || !ts_packet_queue_.empty();
                    });

                    if (!is_running_) break;

                    if (!ts_packet_queue_.empty()) {
                        data = std::move(ts_packet_queue_.front());
                        ts_packet_queue_.pop_front();
                    }
                }

                if (!data.empty()) {
                    int sent = send(client_sock, (const char*)data.data(), (int)data.size(), 0);
                    if (sent <= 0) break;
                }
            }
            CLOSE_SOCKET(client_sock);
        }).detach();
    }
    CLOSE_SOCKET(server_fd);
}

std::vector<uint8_t> HttpTsServer::GeneratePat() {
    std::vector<uint8_t> packet(188, 0xFF);
    packet[0] = TS_SYNC_BYTE;
    packet[1] = 0x40 | ((TS_PID_PAT >> 8) & 0x1F); // Payload unit start indicator
    packet[2] = TS_PID_PAT & 0xFF;
    packet[3] = 0x10 | (continuity_pat_++ & 0x0F);
    packet[4] = 0x00; // Pointer field

    // Table ID 0x00
    packet[5] = 0x00;
    packet[6] = 0xB0;
    packet[7] = 0x0D; // Section length: 13
    packet[8] = 0x00; packet[9] = 0x01; // Transport stream ID
    packet[10] = 0xC1; // version 0, current
    packet[11] = 0x00; // section number
    packet[12] = 0x00; // last section number
    // Program 1 -> PMT PID
    packet[13] = 0x00; packet[14] = 0x01;
    packet[15] = 0xE0 | ((TS_PID_PMT >> 8) & 0x1F);
    packet[16] = TS_PID_PMT & 0xFF;
    // CRC32 dummy
    packet[17] = 0x2A; packet[18] = 0xB1; packet[19] = 0x04; packet[20] = 0xB2;
    return packet;
}

std::vector<uint8_t> HttpTsServer::GeneratePmt() {
    std::vector<uint8_t> packet(188, 0xFF);
    packet[0] = TS_SYNC_BYTE;
    packet[1] = 0x40 | ((TS_PID_PMT >> 8) & 0x1F);
    packet[2] = TS_PID_PMT & 0xFF;
    packet[3] = 0x10 | (continuity_pmt_++ & 0x0F);
    packet[4] = 0x00; // Pointer field

    // Table ID 0x02
    packet[5] = 0x02;
    packet[6] = 0xB0;
    packet[7] = 0x17; // Section length: 23
    packet[8] = 0x00; packet[9] = 0x01; // Program number 1
    packet[10] = 0xC1;
    packet[11] = 0x00;
    packet[12] = 0x00;
    packet[13] = 0xE0 | ((TS_PID_VIDEO >> 8) & 0x1F); // PCR PID
    packet[14] = TS_PID_VIDEO & 0xFF;
    packet[15] = 0xF0; packet[16] = 0x00; // Program info length = 0

    // Stream 1: H.264 Video (0x1B)
    packet[17] = 0x1B;
    packet[18] = 0xE0 | ((TS_PID_VIDEO >> 8) & 0x1F);
    packet[19] = TS_PID_VIDEO & 0xFF;
    packet[20] = 0xF0; packet[21] = 0x00;

    // Stream 2: AAC Audio (0x0F)
    packet[22] = 0x0F;
    packet[23] = 0xE0 | ((TS_PID_AUDIO >> 8) & 0x1F);
    packet[24] = TS_PID_AUDIO & 0xFF;
    packet[25] = 0xF0; packet[26] = 0x00;

    // CRC32 dummy
    packet[27] = 0x45; packet[28] = 0xBD; packet[29] = 0xDC; packet[30] = 0xF4;
    return packet;
}

std::vector<uint8_t> HttpTsServer::PackPesToTs(uint16_t pid, uint8_t& continuity, const uint8_t* payload, size_t len, uint64_t pts, bool is_video, bool is_keyframe) {
    // 构造 PES 头
    std::vector<uint8_t> pes;
    pes.reserve(19 + len);
    // 0x000001
    pes.push_back(0x00); pes.push_back(0x00); pes.push_back(0x01);
    // stream_id (Video: 0xE0, Audio: 0xC0)
    pes.push_back(is_video ? 0xE0 : 0xC0);
    // PES packet length (0 表示视频无限制或特定长度)
    uint16_t pes_len = (len + 8 > 0xFFFF) ? 0 : static_cast<uint16_t>(len + 8);
    pes.push_back((pes_len >> 8) & 0xFF);
    pes.push_back(pes_len & 0xFF);

    // Flag: PTS present
    pes.push_back(0x80);
    pes.push_back(0x80); // PTS flag = 1
    pes.push_back(0x05); // Header data length = 5

    // 33-bit PTS
    uint64_t pts_90k = (pts * 9) / 100;
    pes.push_back(static_cast<uint8_t>(0x21 | (((pts_90k >> 30) & 0x07) << 1)));
    pes.push_back(static_cast<uint8_t>((pts_90k >> 22) & 0xFF));
    pes.push_back(static_cast<uint8_t>(0x01 | (((pts_90k >> 15) & 0x7F) << 1)));
    pes.push_back(static_cast<uint8_t>((pts_90k >> 7) & 0xFF));
    pes.push_back(static_cast<uint8_t>(0x01 | ((pts_90k & 0x7F) << 1)));

    // 数据载入
    pes.insert(pes.end(), payload, payload + len);

    // 将 PES 切割填入一个个 188 字节的 TS 包中
    std::vector<uint8_t> result;
    size_t offset = 0;
    bool is_first = true;

    while (offset < pes.size()) {
        std::vector<uint8_t> ts(188, 0xFF);
        ts[0] = TS_SYNC_BYTE;
        ts[1] = (is_first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F);
        ts[2] = pid & 0xFF;
        ts[3] = 0x10 | (continuity++ & 0x0F);

        size_t header_len = 4;
        size_t remaining = pes.size() - offset;
        size_t available_payload = 188 - header_len;

        if (remaining < available_payload) {
            // 需要 Adaptation field 填充 stuffing bytes
            size_t stuffing_len = available_payload - remaining;
            ts[3] |= 0x20; // Adaptation field flag
            ts[4] = static_cast<uint8_t>(stuffing_len - 1);
            if (stuffing_len > 1) {
                ts[5] = 0x00; // flags
                std::memset(ts.data() + 6, 0xFF, stuffing_len - 2);
            }
            header_len += stuffing_len;
        }

        size_t to_copy = 188 - header_len;
        std::memcpy(ts.data() + header_len, pes.data() + offset, to_copy);
        offset += to_copy;
        is_first = false;

        result.insert(result.end(), ts.begin(), ts.end());
    }

    return result;
}

void HttpTsServer::PushH264Nalu(const uint8_t* data, size_t size, bool is_keyframe, uint64_t pts_us) {
    if (!is_running_) return;
    auto ts_data = PackPesToTs(TS_PID_VIDEO, continuity_video_, data, size, pts_us, true, is_keyframe);
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        if (ts_packet_queue_.size() > 50) {
            ts_packet_queue_.pop_front(); // 控流，防止内存无限累积延迟
        }
        ts_packet_queue_.push_back(std::move(ts_data));
    }
    queue_cv_.notify_one();
}

void HttpTsServer::PushAacFrame(const uint8_t* data, size_t size, uint64_t pts_us) {
    if (!is_running_) return;
    auto ts_data = PackPesToTs(TS_PID_AUDIO, continuity_audio_, data, size, pts_us, false, false);
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        if (ts_packet_queue_.size() > 50) {
            ts_packet_queue_.pop_front();
        }
        ts_packet_queue_.push_back(std::move(ts_data));
    }
    queue_cv_.notify_one();
}

} // namespace media
} // namespace acast

