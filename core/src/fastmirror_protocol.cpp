#include "fastmirror_protocol.h"
#include <chrono>
#include <cstring>

#if defined(_WIN32)
#include <winsock2.h>
#else
#include <arpa/inet.h>
#endif

namespace acast {
namespace fastmirror {

static uint64_t GetCurrentTimestampUs() {
    auto now = std::chrono::steady_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::microseconds>(now).count();
}

std::vector<uint8_t> ProtocolCodec::Pack(MessageType type, const uint8_t* payload, uint32_t payload_len, uint64_t timestamp_us) {
    if (timestamp_us == 0) {
        timestamp_us = GetCurrentTimestampUs();
    }

    Header header;
    header.magic = MAGIC_NUMBER;
    header.msg_type = static_cast<uint8_t>(type);
    header.flags = 0;
    header.payload_len = htonl(payload_len);
    
    // 64-bit 时间戳高低位转网络序
    uint32_t high = htonl(static_cast<uint32_t>(timestamp_us >> 32));
    uint32_t low = htonl(static_cast<uint32_t>(timestamp_us & 0xFFFFFFFF));
    header.timestamp_us = (static_cast<uint64_t>(high) << 32) | low;

    std::vector<uint8_t> packet(sizeof(Header) + payload_len);
    std::memcpy(packet.data(), &header, sizeof(Header));

    if (payload && payload_len > 0) {
        std::memcpy(packet.data() + sizeof(Header), payload, payload_len);
    }

    return packet;
}

bool ProtocolCodec::UnpackHeader(const uint8_t* buffer, size_t buffer_len, Header& out_header) {
    if (buffer_len < sizeof(Header)) {
        return false;
    }

    std::memcpy(&out_header, buffer, sizeof(Header));

    if (out_header.magic != MAGIC_NUMBER) {
        return false;
    }

    out_header.payload_len = ntohl(out_header.payload_len);

    uint32_t high = ntohl(static_cast<uint32_t>(out_header.timestamp_us >> 32));
    uint32_t low = ntohl(static_cast<uint32_t>(out_header.timestamp_us & 0xFFFFFFFF));
    out_header.timestamp_us = (static_cast<uint64_t>(high) << 32) | low;

    return true;
}

} // namespace fastmirror
} // namespace acast

