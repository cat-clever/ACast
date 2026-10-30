#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace acast {
namespace fastmirror {

// 协议魔数: 'F' (0x46), 'M' (0x4D)
constexpr uint16_t MAGIC_NUMBER = 0x4D46; // Little Endian representation of "FM"

// 默认通信端口
constexpr uint16_t DEFAULT_CONTROL_PORT = 19999;
constexpr uint16_t DEFAULT_MEDIA_PORT = 19998;

// 消息类型定义
enum class MessageType : uint8_t {
    // 握手与连接控制 (0x01 - 0x0F)
    HANDSHAKE_REQ = 0x01,
    HANDSHAKE_RESP = 0x02,
    PING = 0x03,
    PONG = 0x04,
    DISCONNECT = 0x05,

    // 媒体流传输 (0x06 - 0x0F)
    VIDEO_FRAME = 0x06,       // H.264 / H.265 NALU
    AUDIO_FRAME = 0x07,       // AAC / Opus / PCM
    MEDIA_CONFIG = 0x08,      // 视频分辨率、帧率、音频采样率等配置

    // 触控反向控制 (0x10 - 0x1F)
    TOUCH_DOWN = 0x10,
    TOUCH_MOVE = 0x11,
    TOUCH_UP = 0x12,
    TOUCH_CANCEL = 0x13,

    // 键盘与物理按键反向控制 (0x20 - 0x2F)
    KEY_DOWN = 0x20,
    KEY_UP = 0x21,
    TEXT_INPUT = 0x22,        // UTF-8 字符上屏
    SYSTEM_KEY = 0x23,        // BACK, HOME, APP_SWITCH, VOLUME_UP, VOLUME_DOWN, POWER

    // 辅助与状态同步 (0x30 - 0x3F)
    CLIPBOARD_SYNC = 0x30,
    ORIENTATION_CHANGE = 0x31
};

// 系统按键枚举
enum class SystemKeyCode : uint16_t {
    KEY_BACK = 1,
    KEY_HOME = 2,
    KEY_APP_SWITCH = 3,
    KEY_VOLUME_UP = 4,
    KEY_VOLUME_DOWN = 5,
    KEY_POWER = 6
};

#pragma pack(push, 1)

// 协议二进制统一消息头 (共 16 字节)
struct Header {
    uint16_t magic;          // 'FM'
    uint8_t  msg_type;       // MessageType
    uint8_t  flags;          // 保留或压缩标识
    uint32_t payload_len;    // 负载字节长度 (网络字节序 / Big Endian)
    uint64_t timestamp_us;   // 发送时间戳 (微秒)
};

// 握手请求包
struct HandshakeReqPayload {
    uint16_t client_version;
    uint8_t  platform;       // 1: Windows, 2: macOS, 3: Android, 4: iOS
    uint8_t  device_name_len;
    char     device_name[64];
};

// 握手响应包
struct HandshakeRespPayload {
    uint16_t server_version;
    uint8_t  status;         // 0: 成功, 1: 认证拒绝, 2: 忙碌
    uint16_t screen_width;
    uint16_t screen_height;
    uint8_t  fps;
};

// 视频帧描述包
struct VideoFrameHeader {
    uint8_t  codec;          // 1: H.264, 2: H.265
    uint8_t  is_keyframe;    // 1: 关键帧(IDR), 0: 非关键帧
    uint32_t frame_index;
    uint64_t pts_us;         // 呈现时间戳
};

// 触控事件载荷
struct TouchPayload {
    uint8_t  pointer_id;     // 触点 ID (支持多点触控 0~9)
    uint16_t x;              // 归一化坐标 X (0 ~ 10000 映射至全屏宽度)
    uint16_t y;              // 归一化坐标 Y (0 ~ 10000 映射至全屏高度)
    uint16_t pressure;       // 压力值 (默认 1000)
};

// 物理按键载荷
struct KeyPayload {
    uint16_t key_code;       // SystemKeyCode 或标准扫描码
    uint8_t  action;         // 0: 按下, 1: 抬起
};

#pragma pack(pop)

// 封包与解包实用工具
class ProtocolCodec {
public:
    static std::vector<uint8_t> Pack(MessageType type, const uint8_t* payload, uint32_t payload_len, uint64_t timestamp_us = 0);
    static bool UnpackHeader(const uint8_t* buffer, size_t buffer_len, Header& out_header);
};

} // namespace fastmirror
} // namespace acast

