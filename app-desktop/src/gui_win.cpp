#if defined(_WIN32)

#include <windows.h>
#include <commctrl.h>
#include <string>
#include <vector>
#include "gui_interface.h"
#include "desktop_controller.h"
#include "auto_updater.h"

#pragma comment(lib, "comctl32.lib")

#define IDC_BTN_CHECK_UPDATE   1001
#define IDC_BTN_PERFORM_UPDATE 1002
#define IDC_BTN_REFRESH_USB    1003
#define IDC_BTN_USB_BACK       1004
#define IDC_BTN_USB_HOME       1005
#define IDC_BTN_CLEAR_LOG      1007
#define IDC_EDIT_LOG           1008
#define IDC_LABEL_USB_STATUS   1010
#define IDC_LABEL_UPDATE_INFO  1011
#define IDC_BTN_CONNECT_WIFI   1012
#define IDC_EDIT_WIFI_IP       1013
#define IDC_EDIT_WIFI_PORT     1014
#define IDC_LABEL_WIFI_STATUS  1015
#define IDC_BTN_USB_RECENTS    1016

#define WM_ACAST_LOG           (WM_USER + 101)
#define WM_ACAST_USB_UPDATE    (WM_USER + 103)
#define WM_ACAST_UPDATE_INFO   (WM_USER + 104)
#define WM_ACAST_UPDATE_PROG   (WM_USER + 105)
#define WM_ACAST_FM_UPDATE     (WM_USER + 106)

static HWND g_hWnd = NULL;
static HWND g_hEditLog = NULL;
static HWND g_hLabelUsb = NULL;
static HWND g_hLabelUpdate = NULL;
static HWND g_hBtnUpdate = NULL;
static HWND g_hEditWifiIp = NULL;
static HWND g_hEditWifiPort = NULL;
static HWND g_hBtnConnectWifi = NULL;
static HWND g_hLabelWifi = NULL;
static HFONT g_hFontNormal = NULL;
static HFONT g_hFontBold = NULL;
static HFONT g_hFontMono = NULL;

static std::wstring Utf8ToWide(const std::string& str) {
    if (str.empty()) return L"";
    int size = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, NULL, 0);
    std::wstring wstr(size, 0);
    MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &wstr[0], size);
    if (!wstr.empty() && wstr.back() == L'\0') wstr.pop_back();
    return wstr;
}

LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE:
        break;

    case WM_COMMAND: {
        int id = LOWORD(wParam);
        if (id == IDC_BTN_CHECK_UPDATE) {
            acast::desktop::DesktopController::GetInstance().CheckUpdateAsync();
        } else if (id == IDC_BTN_PERFORM_UPDATE) {
            EnableWindow(g_hBtnUpdate, FALSE);
            acast::desktop::DesktopController::GetInstance().PerformUpdateAsync([](const std::string& status, int progress) {
                std::string* p = new std::string(status + " (" + std::to_string(progress) + "%)");
                PostMessage(g_hWnd, WM_ACAST_UPDATE_PROG, (WPARAM)progress, (LPARAM)p);
            });
        } else if (id == IDC_BTN_CONNECT_WIFI) {
            auto& ctl = acast::desktop::DesktopController::GetInstance();
            if (ctl.IsWifiPhoneConnected()) {
                ctl.DisconnectWifiPhone();
            } else {
                wchar_t ipBuf[64] = {0};
                wchar_t portBuf[16] = {0};
                GetWindowTextW(g_hEditWifiIp, ipBuf, 64);
                GetWindowTextW(g_hEditWifiPort, portBuf, 16);
                int port = _wtoi(portBuf);
                if (port <= 0) port = 19999;
                char utf8Ip[128] = {0};
                WideCharToMultiByte(CP_UTF8, 0, ipBuf, -1, utf8Ip, sizeof(utf8Ip), NULL, NULL);
                ctl.ConnectWifiPhone(utf8Ip, (uint16_t)port);
            }
        } else if (id == IDC_BTN_REFRESH_USB) {
            acast::desktop::DesktopController::GetInstance().RefreshUsbDevices();
        } else if (id == IDC_BTN_USB_BACK) {
            acast::desktop::DesktopController::GetInstance().SendBackKey();
        } else if (id == IDC_BTN_USB_HOME) {
            acast::desktop::DesktopController::GetInstance().SendHomeKey();
        } else if (id == IDC_BTN_USB_RECENTS) {
            acast::desktop::DesktopController::GetInstance().SendRecentsKey();
        } else if (id == IDC_BTN_CLEAR_LOG) {
            SetWindowTextW(g_hEditLog, L"");
        }
        break;
    }

    case WM_ACAST_LOG: {
        std::string* pStr = reinterpret_cast<std::string*>(lParam);
        if (pStr && g_hEditLog) {
            std::wstring line = Utf8ToWide(*pStr + "\r\n");
            int len = GetWindowTextLengthW(g_hEditLog);
            SendMessageW(g_hEditLog, EM_SETSEL, (WPARAM)len, (LPARAM)len);
            SendMessageW(g_hEditLog, EM_REPLACESEL, FALSE, (LPARAM)line.c_str());
            SendMessageW(g_hEditLog, WM_VSCROLL, SB_BOTTOM, 0);
            delete pStr;
        }
        break;
    }

    case WM_ACAST_FM_UPDATE: {
        bool connected = (wParam != 0);
        std::string* pAddr = reinterpret_cast<std::string*>(lParam);
        if (g_hLabelWifi && g_hBtnConnectWifi) {
            if (connected && pAddr) {
                std::string text = "✓ 已直连: " + *pAddr + " (私有协议延迟<20ms)";
                SetWindowTextW(g_hLabelWifi, Utf8ToWide(text).c_str());
                SetWindowTextW(g_hBtnConnectWifi, L"断开直连");
            } else {
                SetWindowTextW(g_hLabelWifi, L"Wi-Fi 状态: 未连接 (输入手机IP点击连接)");
                SetWindowTextW(g_hBtnConnectWifi, L"连接 Wi-Fi");
            }
        }
        if (pAddr) delete pAddr;
        break;
    }

    case WM_ACAST_USB_UPDATE: {
        if (g_hLabelUsb) {
            auto devs = acast::desktop::DesktopController::GetInstance().GetUsbDevices();
            if (devs.empty()) {
                SetWindowTextW(g_hLabelUsb, L"USB 状态: 未检测到手机 (支持无线或插线)");
            } else {
                std::string desc = "USB 已连接: " + devs[0].model + " (" + devs[0].serial + ") [通道已就绪]";
                SetWindowTextW(g_hLabelUsb, Utf8ToWide(desc).c_str());
            }
        }
        break;
    }

    case WM_ACAST_UPDATE_INFO: {
        auto info = acast::desktop::DesktopController::GetInstance().GetLastUpdateInfo();
        if (info.has_update) {
            std::string text = "🎉 发现新版本: " + info.latest_version + " (当前: " + info.current_version + ")";
            SetWindowTextW(g_hLabelUpdate, Utf8ToWide(text).c_str());
            ShowWindow(g_hLabelUpdate, SW_SHOW);
            ShowWindow(g_hBtnUpdate, SW_SHOW);
            EnableWindow(g_hBtnUpdate, TRUE);
        } else {
            ShowWindow(g_hLabelUpdate, SW_HIDE);
            ShowWindow(g_hBtnUpdate, SW_HIDE);
        }
        break;
    }

    case WM_ACAST_UPDATE_PROG: {
        std::string* pStr = reinterpret_cast<std::string*>(lParam);
        if (pStr) {
            SetWindowTextW(g_hLabelUpdate, Utf8ToWide(*pStr).c_str());
            delete pStr;
        }
        break;
    }

    case WM_DESTROY:
        acast::desktop::DesktopController::GetInstance().Cleanup();
        PostQuitMessage(0);
        break;

    default:
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }
    return 0;
}

namespace acast {
namespace desktop {

int RunDesktopApp(int argc, char* argv[]) {
    INITCOMMONCONTROLSEX icex;
    icex.dwSize = sizeof(INITCOMMONCONTROLSEX);
    icex.dwICC = ICC_WIN95_CLASSES | ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&icex);

    HINSTANCE hInstance = GetModuleHandle(NULL);
    const wchar_t CLASS_NAME[] = L"ACastDesktopWindowClass";

    WNDCLASSEXW wc = { 0 };
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = CLASS_NAME;
    wc.hIcon = LoadIcon(hInstance, MAKEINTRESOURCE(101));
    RegisterClassExW(&wc);

    g_hWnd = CreateWindowExW(
        0,
        CLASS_NAME,
        L"ACast 跨平台投屏控制台",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 800, 720,
        NULL, NULL, hInstance, NULL
    );

    if (!g_hWnd) return -1;

    g_hFontNormal = CreateFontW(-13, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");
    g_hFontBold   = CreateFontW(-15, 0, 0, 0, FW_BOLD,   FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");
    g_hFontMono   = CreateFontW(-12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN,    L"Consolas");

    // 1. 顶部 Header
    HWND hTitle = CreateWindowExW(0, L"STATIC", L"ACast 跨平台投屏控制端", WS_CHILD | WS_VISIBLE | SS_LEFT, 20, 15, 260, 25, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hTitle, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);

    std::wstring verStr = L"v" + Utf8ToWide(acast::updater::AutoUpdater::CURRENT_VERSION);
    HWND hVer = CreateWindowExW(0, L"STATIC", verStr.c_str(), WS_CHILD | WS_VISIBLE | SS_LEFT, 280, 18, 120, 20, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hVer, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnCheck = CreateWindowExW(0, L"BUTTON", L"检查更新", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 660, 12, 100, 30, g_hWnd, (HMENU)IDC_BTN_CHECK_UPDATE, hInstance, NULL);
    SendMessageW(hBtnCheck, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    // 2. 更新横幅
    g_hLabelUpdate = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | SS_LEFT, 20, 50, 620, 22, g_hWnd, (HMENU)IDC_LABEL_UPDATE_INFO, hInstance, NULL);
    SendMessageW(g_hLabelUpdate, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);

    g_hBtnUpdate = CreateWindowExW(0, L"BUTTON", L"原地热更新", WS_CHILD | BS_PUSHBUTTON, 650, 48, 110, 26, g_hWnd, (HMENU)IDC_BTN_PERFORM_UPDATE, hInstance, NULL);
    SendMessageW(g_hBtnUpdate, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    // 3. 手机反控中心 (FastMirror 局域网直连 / USB 专线) GroupBox
    HWND hBoxPhone = CreateWindowExW(0, L"BUTTON", L"📱 手机反控中心 (FastMirror 局域网直连 / USB 专线)", WS_CHILD | WS_VISIBLE | BS_GROUPBOX, 20, 80, 740, 115, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hBoxPhone, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);

    // --- 第 1 行：局域网 Wi-Fi IP 直连 ---
    HWND hLabelIp = CreateWindowExW(0, L"STATIC", L"局域网手机 IP:", WS_CHILD | WS_VISIBLE | SS_LEFT, 35, 108, 95, 20, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hLabelIp, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    g_hEditWifiIp = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"192.168.2.3", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 135, 106, 120, 24, g_hWnd, (HMENU)IDC_EDIT_WIFI_IP, hInstance, NULL);
    SendMessageW(g_hEditWifiIp, WM_SETFONT, (WPARAM)g_hFontMono, TRUE);

    HWND hLabelPort = CreateWindowExW(0, L"STATIC", L"端口:", WS_CHILD | WS_VISIBLE | SS_LEFT, 265, 108, 38, 20, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hLabelPort, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    g_hEditWifiPort = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"19999", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 305, 106, 55, 24, g_hWnd, (HMENU)IDC_EDIT_WIFI_PORT, hInstance, NULL);
    SendMessageW(g_hEditWifiPort, WM_SETFONT, (WPARAM)g_hFontMono, TRUE);

    g_hBtnConnectWifi = CreateWindowExW(0, L"BUTTON", L"连接 Wi-Fi", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 368, 104, 95, 28, g_hWnd, (HMENU)IDC_BTN_CONNECT_WIFI, hInstance, NULL);
    SendMessageW(g_hBtnConnectWifi, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    g_hLabelWifi = CreateWindowExW(0, L"STATIC", L"Wi-Fi 状态: 未连接 (输入手机IP点击连接)", WS_CHILD | WS_VISIBLE | SS_LEFT, 472, 108, 275, 20, g_hWnd, (HMENU)IDC_LABEL_WIFI_STATUS, hInstance, NULL);
    SendMessageW(g_hLabelWifi, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    // --- 第 2 行：USB 状态与反控按键 ---
    g_hLabelUsb = CreateWindowExW(0, L"STATIC", L"正在检测 USB 手机...", WS_CHILD | WS_VISIBLE | SS_LEFT, 35, 150, 275, 22, g_hWnd, (HMENU)IDC_LABEL_USB_STATUS, hInstance, NULL);
    SendMessageW(g_hLabelUsb, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnRefUsb = CreateWindowExW(0, L"BUTTON", L"刷新 USB", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 315, 146, 85, 28, g_hWnd, (HMENU)IDC_BTN_REFRESH_USB, hInstance, NULL);
    SendMessageW(hBtnRefUsb, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnBack = CreateWindowExW(0, L"BUTTON", L"返回 (Back)", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 408, 146, 95, 28, g_hWnd, (HMENU)IDC_BTN_USB_BACK, hInstance, NULL);
    SendMessageW(hBtnBack, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnHome = CreateWindowExW(0, L"BUTTON", L"桌面 (Home)", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 510, 146, 95, 28, g_hWnd, (HMENU)IDC_BTN_USB_HOME, hInstance, NULL);
    SendMessageW(hBtnHome, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnRecents = CreateWindowExW(0, L"BUTTON", L"任务 (Tasks)", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 612, 146, 100, 28, g_hWnd, (HMENU)IDC_BTN_USB_RECENTS, hInstance, NULL);
    SendMessageW(hBtnRecents, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    // 4. 运行状态与事件日志 GroupBox (占满下方大空间)
    HWND hBoxLog = CreateWindowExW(0, L"BUTTON", L"📋 运行状态与事件日志", WS_CHILD | WS_VISIBLE | BS_GROUPBOX, 20, 205, 740, 460, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hBoxLog, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);

    HWND hBtnClear = CreateWindowExW(0, L"BUTTON", L"清空", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 675, 225, 75, 26, g_hWnd, (HMENU)IDC_BTN_CLEAR_LOG, hInstance, NULL);
    SendMessageW(hBtnClear, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    g_hEditLog = CreateWindowExW(
        WS_EX_CLIENTEDGE, L"EDIT", L"",
        WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,
        35, 260, 715, 390, g_hWnd, (HMENU)IDC_EDIT_LOG, hInstance, NULL
    );
    SendMessageW(g_hEditLog, WM_SETFONT, (WPARAM)g_hFontMono, TRUE);

    // 5. 注册 Controller 线程安全回调
    auto& ctl = acast::desktop::DesktopController::GetInstance();

    ctl.SetLogCallback([](std::string line) {
        if (g_hWnd) {
            std::string* p = new std::string(line);
            PostMessage(g_hWnd, WM_ACAST_LOG, 0, (LPARAM)p);
        }
    });

    ctl.SetFastMirrorCallback([](bool connected, std::string addr) {
        if (g_hWnd) {
            std::string* p = new std::string(addr);
            PostMessage(g_hWnd, WM_ACAST_FM_UPDATE, connected ? 1 : 0, (LPARAM)p);
        }
    });

    ctl.SetUsbDeviceCallback([](std::vector<acast::adb::AdbDevice>) {
        if (g_hWnd) {
            PostMessage(g_hWnd, WM_ACAST_USB_UPDATE, 0, 0);
        }
    });

    ctl.SetUpdateCallback([](acast::updater::UpdateInfo) {
        if (g_hWnd) {
            PostMessage(g_hWnd, WM_ACAST_UPDATE_INFO, 0, 0);
        }
    });

    ShowWindow(g_hWnd, SW_SHOW);
    UpdateWindow(g_hWnd);

    // 启动核心后台服务
    ctl.Init();

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    return (int)msg.wParam;
}

} // namespace desktop
} // namespace acast

#endif // _WIN32
