#include "dlna_controller.h"
#include <iostream>
#include <sstream>
#include <cstring>
#include <regex>

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
using socket_t = int;
#define IS_VALID_SOCKET(s) ((s) >= 0)
#define CLOSE_SOCKET(s) close(s)
#endif

namespace acast {
namespace dlna {

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

DlnaController::DlnaController() {
    InitSockets();
}

DlnaController::~DlnaController() {
    StopDiscovery();
}

void DlnaController::StartDiscovery(DeviceFoundCallback on_found) {
    if (is_discovering_) return;
    is_discovering_ = true;

    discovery_thread_ = std::make_unique<std::thread>([this, on_found]() {
        socket_t sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (!IS_VALID_SOCKET(sock)) return;

        // 设置组播广播 TTL 与超时
        int ttl = 4;
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, (char*)&ttl, sizeof(ttl));

#if defined(_WIN32)
        DWORD timeout = 2000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout, sizeof(timeout));
#else
        struct timeval tv;
        tv.tv_sec = 2;
        tv.tv_usec = 0;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#endif

        // SSDP M-SEARCH 探测报文 (对标 B 站、爱奇艺投屏搜索)
        const char* msearch =
            "M-SEARCH * HTTP/1.1\r\n"
            "HOST: 239.255.255.250:1900\r\n"
            "MAN: \"ssdp:discover\"\r\n"
            "MX: 3\r\n"
            "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"
            "\r\n";

        struct sockaddr_in dest;
        std::memset(&dest, 0, sizeof(dest));
        dest.sin_family = AF_INET;
        dest.sin_port = htons(1900);
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr);

        sendto(sock, msearch, (int)std::strlen(msearch), 0, (struct sockaddr*)&dest, sizeof(dest));

        char buffer[2048];
        while (is_discovering_) {
            struct sockaddr_in src;
            socklen_t src_len = sizeof(src);
            int n = recvfrom(sock, buffer, sizeof(buffer) - 1, 0, (struct sockaddr*)&src, &src_len);
            if (n > 0) {
                buffer[n] = '\0';
                std::string resp(buffer);
                std::smatch match;
                // 提取 LOCATION 标头
                std::regex loc_regex("(?i)LOCATION:\\s*([^\\r\\n]+)");
                if (std::regex_search(resp, match, loc_regex)) {
                    std::string location = match[1].str();
                    DlnaDevice dev;
                    dev.location_url = location;
                    char ip_buf[INET_ADDRSTRLEN];
                    inet_ntop(AF_INET, &src.sin_addr, ip_buf, sizeof(ip_buf));
                    dev.ip_address = ip_buf;

                    if (ParseLocationXml(location, dev)) {
                        if (on_found) {
                            on_found(dev);
                        }
                    }
                }
            }
        }
        CLOSE_SOCKET(sock);
    });
}

void DlnaController::StopDiscovery() {
    is_discovering_ = false;
    if (discovery_thread_ && discovery_thread_->joinable()) {
        discovery_thread_->join();
    }
}

bool DlnaController::ParseLocationXml(const std::string& location_url, DlnaDevice& out_device) {
    // 简易 URL 拆解: http://host:port/path
    std::regex url_regex("http://([^:/]+):?(\\d+)?(/.*)?");
    std::smatch m;
    if (!std::regex_match(location_url, m, url_regex)) {
        return false;
    }

    std::string host = m[1].str();
    int port = m[2].matched ? std::stoi(m[2].str()) : 80;
    std::string path = m[3].matched ? m[3].str() : "/";

    socket_t sock = socket(AF_INET, SOCK_STREAM, 0);
    if (!IS_VALID_SOCKET(sock)) return false;

    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, host.c_str(), &addr.sin_addr);

    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        CLOSE_SOCKET(sock);
        return false;
    }

    std::ostringstream req;
    req << "GET " << path << " HTTP/1.1\r\n"
        << "Host: " << host << ":" << port << "\r\n"
        << "Connection: close\r\n\r\n";

    std::string req_str = req.str();
    send(sock, req_str.c_str(), (int)req_str.length(), 0);

    std::string response;
    char buf[1024];
    int bytes;
    while ((bytes = recv(sock, buf, sizeof(buf) - 1, 0)) > 0) {
        buf[bytes] = '\0';
        response.append(buf, bytes);
    }
    CLOSE_SOCKET(sock);

    // 解析 friendlyName
    std::smatch name_match;
    std::regex name_regex("<friendlyName>([^<]+)</friendlyName>");
    if (std::regex_search(response, name_match, name_regex)) {
        out_device.friendly_name = name_match[1].str();
    } else {
        out_device.friendly_name = "智能电视 (" + host + ")";
    }

    // 解析 controlURL
    std::smatch ctrl_match;
    std::regex ctrl_regex("<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>\\s*<serviceId>[^<]+</serviceId>\\s*<controlURL>([^<]+)</controlURL>");
    if (std::regex_search(response, ctrl_match, ctrl_regex)) {
        std::string rel_ctrl = ctrl_match[1].str();
        if (rel_ctrl.front() != '/') rel_ctrl = "/" + rel_ctrl;
        out_device.control_url = "http://" + host + ":" + std::to_string(port) + rel_ctrl;
    } else {
        out_device.control_url = "http://" + host + ":" + std::to_string(port) + "/AVTransport/control";
    }

    return true;
}

std::string DlnaController::BuildSoapRequest(const std::string& action, const std::string& service_type, const std::string& arguments) {
    std::ostringstream ss;
    ss << "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n"
       << "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\r\n"
       << "  <s:Body>\r\n"
       << "    <u:" << action << " xmlns:u=\"" << service_type << "\">\r\n"
       << arguments
       << "    </u:" << action << ">\r\n"
       << "  </s:Body>\r\n"
       << "</s:Envelope>\r\n";
    return ss.str();
}

bool DlnaController::SendSoapAction(const std::string& host, int port, const std::string& path, const std::string& action, const std::string& soap_body) {
    socket_t sock = socket(AF_INET, SOCK_STREAM, 0);
    if (!IS_VALID_SOCKET(sock)) return false;

    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, host.c_str(), &addr.sin_addr);

    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        CLOSE_SOCKET(sock);
        return false;
    }

    std::ostringstream req;
    req << "POST " << path << " HTTP/1.1\r\n"
        << "Host: " << host << ":" << port << "\r\n"
        << "Content-Type: text/xml; charset=\"utf-8\"\r\n"
        << "Content-Length: " << soap_body.length() << "\r\n"
        << "SOAPACTION: \"urn:schemas-upnp-org:service:AVTransport:1#" << action << "\"\r\n"
        << "Connection: close\r\n\r\n"
        << soap_body;

    std::string req_str = req.str();
    send(sock, req_str.c_str(), (int)req_str.length(), 0);

    char res_buf[1024];
    int n = recv(sock, res_buf, sizeof(res_buf) - 1, 0);
    CLOSE_SOCKET(sock);

    if (n > 0) {
        res_buf[n] = '\0';
        return (std::strstr(res_buf, "200 OK") != nullptr);
    }
    return false;
}

bool DlnaController::SetAVTransportURI(const DlnaDevice& device, const std::string& media_url, const std::string& title) {
    std::regex url_regex("http://([^:/]+):?(\\d+)?(/.*)?");
    std::smatch m;
    if (!std::regex_match(device.control_url, m, url_regex)) return false;

    std::string host = m[1].str();
    int port = m[2].matched ? std::stoi(m[2].str()) : 80;
    std::string path = m[3].matched ? m[3].str() : "/";

    std::ostringstream args;
    args << "      <InstanceID>0</InstanceID>\r\n"
         << "      <CurrentURI>" << media_url << "</CurrentURI>\r\n"
         << "      <CurrentURIMetaData>&lt;DIDL-Lite xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;0&quot; parentID=&quot;-1&quot; restricted=&quot;1&quot;&gt;&lt;dc:title xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot;&gt;" << title << "&lt;/dc:title&gt;&lt;upnp:class xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot;&gt;object.item.videoItem&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>\r\n";

    std::string body = BuildSoapRequest("SetAVTransportURI", "urn:schemas-upnp-org:service:AVTransport:1", args.str());
    return SendSoapAction(host, port, path, "SetAVTransportURI", body);
}

bool DlnaController::Play(const DlnaDevice& device) {
    std::regex url_regex("http://([^:/]+):?(\\d+)?(/.*)?");
    std::smatch m;
    if (!std::regex_match(device.control_url, m, url_regex)) return false;

    std::string host = m[1].str();
    int port = m[2].matched ? std::stoi(m[2].str()) : 80;
    std::string path = m[3].matched ? m[3].str() : "/";

    std::string args = "      <InstanceID>0</InstanceID>\r\n      <Speed>1</Speed>\r\n";
    std::string body = BuildSoapRequest("Play", "urn:schemas-upnp-org:service:AVTransport:1", args);
    return SendSoapAction(host, port, path, "Play", body);
}

bool DlnaController::Pause(const DlnaDevice& device) {
    std::regex url_regex("http://([^:/]+):?(\\d+)?(/.*)?");
    std::smatch m;
    if (!std::regex_match(device.control_url, m, url_regex)) return false;

    std::string host = m[1].str();
    int port = m[2].matched ? std::stoi(m[2].str()) : 80;
    std::string path = m[3].matched ? m[3].str() : "/";

    std::string args = "      <InstanceID>0</InstanceID>\r\n";
    std::string body = BuildSoapRequest("Pause", "urn:schemas-upnp-org:service:AVTransport:1", args);
    return SendSoapAction(host, port, path, "Pause", body);
}

bool DlnaController::Stop(const DlnaDevice& device) {
    std::regex url_regex("http://([^:/]+):?(\\d+)?(/.*)?");
    std::smatch m;
    if (!std::regex_match(device.control_url, m, url_regex)) return false;

    std::string host = m[1].str();
    int port = m[2].matched ? std::stoi(m[2].str()) : 80;
    std::string path = m[3].matched ? m[3].str() : "/";

    std::string args = "      <InstanceID>0</InstanceID>\r\n";
    std::string body = BuildSoapRequest("Stop", "urn:schemas-upnp-org:service:AVTransport:1", args);
    return SendSoapAction(host, port, path, "Stop", body);
}

bool DlnaController::Seek(const DlnaDevice& device, const std::string& target_time) {
    std::regex url_regex("http://([^:/]+):?(\\d+)?(/.*)?");
    std::smatch m;
    if (!std::regex_match(device.control_url, m, url_regex)) return false;

    std::string host = m[1].str();
    int port = m[2].matched ? std::stoi(m[2].str()) : 80;
    std::string path = m[3].matched ? m[3].str() : "/";

    std::ostringstream args;
    args << "      <InstanceID>0</InstanceID>\r\n"
         << "      <Unit>REL_TIME</Unit>\r\n"
         << "      <Target>" << target_time << "</Target>\r\n";

    std::string body = BuildSoapRequest("Seek", "urn:schemas-upnp-org:service:AVTransport:1", args.str());
    return SendSoapAction(host, port, path, "Seek", body);
}

bool DlnaController::SetVolume(const DlnaDevice& device, int volume) {
    // 渲染控制服务
    return true;
}

} // namespace dlna
} // namespace acast
