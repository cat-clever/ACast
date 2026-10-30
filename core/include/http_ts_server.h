#pragma once

#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <deque>

namespace acast {
namespace media {

class HttpTsServer {
public:
    HttpTsServer(int port = 8088);
    ~HttpTsServer();

    bool Start();
    void Stop();

    // 接收编码后的音视频帧，封装为 MPEG-TS 并分发给所有连接的电视客户端
    void PushH264Nalu(const uint8_t* data, size_t size, bool is_keyframe, uint64_t pts_us);
    void PushAacFrame(const uint8_t* data, size_t size, uint64_t pts_us);

    std::string GetStreamUrl(const std::string& local_ip) const;
    int GetPort() const { return port_; }

private:
    int port_;
    std::atomic<bool> is_running_{false};
    std::unique_ptr<std::thread> server_thread_;

    // 极简 MPEG-TS 实时复用器状态
    uint8_t continuity_video_{0};
    uint8_t continuity_audio_{0};
    uint8_t continuity_pat_{0};
    uint8_t continuity_pmt_{0};

    std::mutex queue_mutex_;
    std::condition_variable queue_cv_;
    std::deque<std::vector<uint8_t>> ts_packet_queue_;

    void RunServer();
    std::vector<uint8_t> GeneratePat();
    std::vector<uint8_t> GeneratePmt();
    std::vector<uint8_t> PackPesToTs(uint16_t pid, uint8_t& continuity, const uint8_t* payload, size_t len, uint64_t pts, bool is_video, bool is_keyframe);
};

} // namespace media
} // namespace acast

