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
#define IDC_BTN_REFRESH_PHONE  1003
#define IDC_BTN_USB_BACK       1004
#define IDC_BTN_USB_HOME       1005
#define IDC_BTN_CLEAR_LOG      1007
#define IDC_EDIT_LOG           1008
#define IDC_LABEL_USB_STATUS   1010
#define IDC_LABEL_UPDATE_INFO  1011
#define IDC_BTN_CONNECT_PHONE  1012
#define IDC_COMBO_PHONE        1013
#define IDC_LABEL_PHONE_STATUS 1015
#define IDC_BTN_USB_RECENTS    1016

#define WM_ACAST_LOG           (WM_USER + 101)
#define WM_ACAST_USB_UPDATE    (WM_USER + 103)
#define WM_ACAST_UPDATE_INFO   (WM_USER + 104)
#define WM_ACAST_UPDATE_PROG   (WM_USER + 105)
#define WM_ACAST_FM_UPDATE     (WM_USER + 106)
#define WM_ACAST_PHONE_UPDATE  (WM_USER + 107)

static HWND g_hWnd = NULL;
static HWND g_hEditLog = NULL;
static HWND g_hLabelUsb = NULL;
static HWND g_hLabelUpdate = NULL;
static HWND g_hBtnUpdate = NULL;
static HWND g_hComboPhone = NULL;
static HWND g_hBtnConnectPhone = NULL;
static HWND g_hLabelPhoneStatus = NULL;
static HFONT g_hFontNormal = NULL;
static HFONT g_hFontBold = NULL;
static HFONT g_hFontMono = NULL;

struct PhoneItemData {
    bool is_wifi;
    std::string ip;
    uint16_t port;
    std::string serial;
};
static std::vector<PhoneItemData> g_phoneItems;

static std::wstring Utf8ToWide(const std::string& str) {
    if (str.empty()) return L"";
    int size = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, NULL, 0);
    std::wstring wstr(size, 0);
    MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &wstr[0], size);
    if (!wstr.empty() && wstr.back() == L'\0') wstr.pop_back();
    return wstr;
}

static void ReloadPhoneComboBox() {
    if (!g_hComboPhone) return;
    SendMessageW(g_hComboPhone, CB_RESETCONTENT, 0, 0);
    g_phoneItems.clear();

    auto phones = acast::desktop::DesktopController::GetInstance().GetDiscoveredPhones();
    auto usbDevs = acast::desktop::DesktopController::GetInstance().GetUsbDevices();

    // 1. 添加局域网 Wi-Fi 手机
    for (const auto& p : phones) {
        std::string text = "📱 " + p.name + " (" + p.ip + ")";
        SendMessageW(g_hComboPhone, CB_ADDSTRING, 0, (LPARAM)Utf8ToWide(text).c_str());
        PhoneItemData item;
        item.is_wifi = true;
        item.ip = p.ip;
        item.port = p.port;
        g_phoneItems.push_back(item);
    }

    // 2. 添加 USB 专线连入的手机
    for (const auto& u : usbDevs) {
        std::string text = "🔌 " + u.model + " (USB专线)";
        SendMessageW(g_hComboPhone, CB_ADDSTRING, 0, (LPARAM)Utf8ToWide(text).c_str());
        PhoneItemData item;
        item.is_wifi = false;
        item.serial = u.serial;
        g_phoneItems.push_back(item);
    }

    if (g_phoneItems.empty()) {
        SendMessageW(g_hComboPhone, CB_ADDSTRING, 0, (LPARAM)L"(未发现手机，请确保手机已开启投屏)");
        SendMessageW(g_hComboPhone, CB_SETCURSEL, 0, 0);
    } else {
        SendMessageW(g_hComboPhone, CB_SETCURSEL, 0, 0);
    }
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
        } else if (id == IDC_BTN_CONNECT_PHONE) {
            auto& ctl = acast::desktop::DesktopController::GetInstance();
            if (ctl.IsWifiPhoneConnected()) {
                ctl.DisconnectWifiPhone();
            } else {
                int curSel = (int)SendMessageW(g_hComboPhone, CB_GETCURSEL, 0, 0);
                if (curSel >= 0 && curSel < (int)g_phoneItems.size()) {
                    const auto& item = g_phoneItems[curSel];
                    if (item.is_wifi) {
                        ctl.ConnectWifiPhone(item.ip, item.port);
                    } else {
                        ctl.Log("[控制端] 正在切换至 USB 专线反控: " + item.serial);
                        ctl.RefreshUsbDevices();
                    }
                } else {
                    ctl.Log("[控制端] 请选择有效的手机设备进行连接！");
                }
            }
        } else if (id == IDC_BTN_REFRESH_PHONE) {
            acast::desktop::DesktopController::GetInstance().RefreshPhones();
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

    case WM_ACAST_PHONE_UPDATE: {
        ReloadPhoneComboBox();
        break;
    }

    case WM_ACAST_FM_UPDATE: {
        bool connected = (wParam != 0);
        std::string* pAddr = reinterpret_cast<std::string*>(lParam);
        if (g_hLabelPhoneStatus && g_hBtnConnectPhone) {
            if (connected && pAddr) {
                std::string text = "✓ 已直连: " + *pAddr + " (延迟<20ms)";
                SetWindowTextW(g_hLabelPhoneStatus, Utf8ToWide(text).c_str());
                SetWindowTextW(g_hBtnConnectPhone, L"断开连接");
            } else {
                SetWindowTextW(g_hLabelPhoneStatus, L"状态: 未连接");
                SetWindowTextW(g_hBtnConnectPhone, L"连接手机");
            }
        }
        if (pAddr) delete pAddr;
        break;
    }

    case WM_ACAST_USB_UPDATE: {
        ReloadPhoneComboBox();
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
        acast::updater::UpdateInfo* pInfo = reinterpret_cast<acast::updater::UpdateInfo*>(lParam);
        if (pInfo && g_hLabelUpdate && g_hBtnUpdate) {
            if (pInfo->has_update) {
                std::string banner = "🎉 发现新版本: v" + pInfo->latest_version + " (当前: v" +
                                     acast::updater::AutoUpdater::CURRENT_VERSION + ") 点击【原地热更新】自动升级！";
                SetWindowTextW(g_hLabelUpdate, Utf8ToWide(banner).c_str());
                ShowWindow(g_hLabelUpdate, SW_SHOW);
                ShowWindow(g_hBtnUpdate, SW_SHOW);
            }
            delete pInfo;
        }
        break;
    }

    case WM_ACAST_UPDATE_PROG: {
        std::string* pStatus = reinterpret_cast<std::string*>(lParam);
        if (pStatus && g_hLabelUpdate) {
            SetWindowTextW(g_hLabelUpdate, Utf8ToWide(*pStatus).c_str());
            delete pStatus;
        }
        break;
    }

    case WM_DESTROY:
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
    HINSTANCE hInstance = GetModuleHandle(NULL);

    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"ACastDesktopWindowClass";
    RegisterClassExW(&wc);

    g_hFontNormal = CreateFontW(-13, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Microsoft YaHei UI");
    g_hFontBold   = CreateFontW(-14, 0, 0, 0, FW_BOLD,   FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Microsoft YaHei UI");
    g_hFontMono   = CreateFontW(-12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Consolas");

    g_hWnd = CreateWindowExW(
        0, L"ACastDesktopWindowClass", L"ACast 跨平台投屏控制台",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 800, 720,
        NULL, NULL, hInstance, NULL
    );

    if (!g_hWnd) return 1;

    // 1. 顶部 Header
    HWND hTitle = CreateWindowExW(0, L"STATIC", L"ACast 跨平台投屏控制端", WS_CHILD | WS_VISIBLE | SS_LEFT, 20, 16, 260, 24, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hTitle, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);

    std::string verStr = "v" + std::string(acast::updater::AutoUpdater::CURRENT_VERSION);
    HWND hVer = CreateWindowExW(0, L"STATIC", Utf8ToWide(verStr).c_str(), WS_CHILD | WS_VISIBLE | SS_LEFT, 250, 18, 80, 20, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hVer, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnCheckUpdate = CreateWindowExW(0, L"BUTTON", L"检查更新", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 670, 12, 90, 28, g_hWnd, (HMENU)IDC_BTN_CHECK_UPDATE, hInstance, NULL);
    SendMessageW(hBtnCheckUpdate, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    // 2. 更新横幅 (默认隐藏)
    g_hLabelUpdate = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | SS_LEFT, 20, 50, 615, 22, g_hWnd, (HMENU)IDC_LABEL_UPDATE_INFO, hInstance, NULL);
    SendMessageW(g_hLabelUpdate, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);

    g_hBtnUpdate = CreateWindowExW(0, L"BUTTON", L"原地热更新", WS_CHILD | BS_PUSHBUTTON, 650, 48, 110, 26, g_hWnd, (HMENU)IDC_BTN_PERFORM_UPDATE, hInstance, NULL);
    SendMessageW(g_hBtnUpdate, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    // 3. 手机反控中心 GroupBox
    HWND hBoxPhone = CreateWindowExW(0, L"BUTTON", L"📱 手机反控中心 (局域网对等直连 / USB 专线)", WS_CHILD | WS_VISIBLE | BS_GROUPBOX, 20, 80, 740, 115, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hBoxPhone, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);

    // --- 第 1 行：选择手机设备与直连 ---
    HWND hLabelSelect = CreateWindowExW(0, L"STATIC", L"选择手机设备:", WS_CHILD | WS_VISIBLE | SS_LEFT, 35, 108, 90, 20, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hLabelSelect, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    g_hComboPhone = CreateWindowExW(0, L"COMBOBOX", L"", WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 130, 105, 240, 200, g_hWnd, (HMENU)IDC_COMBO_PHONE, hInstance, NULL);
    SendMessageW(g_hComboPhone, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    g_hBtnConnectPhone = CreateWindowExW(0, L"BUTTON", L"连接手机", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 380, 103, 90, 28, g_hWnd, (HMENU)IDC_BTN_CONNECT_PHONE, hInstance, NULL);
    SendMessageW(g_hBtnConnectPhone, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnRefPhone = CreateWindowExW(0, L"BUTTON", L"刷新搜索", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 480, 103, 85, 28, g_hWnd, (HMENU)IDC_BTN_REFRESH_PHONE, hInstance, NULL);
    SendMessageW(hBtnRefPhone, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    g_hLabelPhoneStatus = CreateWindowExW(0, L"STATIC", L"状态: 未连接", WS_CHILD | WS_VISIBLE | SS_LEFT, 575, 108, 175, 20, g_hWnd, (HMENU)IDC_LABEL_PHONE_STATUS, hInstance, NULL);
    SendMessageW(g_hLabelPhoneStatus, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    // --- 第 2 行：USB 状态与反控按键 ---
    g_hLabelUsb = CreateWindowExW(0, L"STATIC", L"正在检测 USB 手机...", WS_CHILD | WS_VISIBLE | SS_LEFT, 35, 150, 360, 22, g_hWnd, (HMENU)IDC_LABEL_USB_STATUS, hInstance, NULL);
    SendMessageW(g_hLabelUsb, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnBack = CreateWindowExW(0, L"BUTTON", L"返回 (Back)", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 408, 146, 95, 28, g_hWnd, (HMENU)IDC_BTN_USB_BACK, hInstance, NULL);
    SendMessageW(hBtnBack, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnHome = CreateWindowExW(0, L"BUTTON", L"桌面 (Home)", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 513, 146, 95, 28, g_hWnd, (HMENU)IDC_BTN_USB_HOME, hInstance, NULL);
    SendMessageW(hBtnHome, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    HWND hBtnRecents = CreateWindowExW(0, L"BUTTON", L"任务 (Tasks)", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 618, 146, 105, 28, g_hWnd, (HMENU)IDC_BTN_USB_RECENTS, hInstance, NULL);
    SendMessageW(hBtnRecents, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    // 4. 运行状态与事件日志视窗
    HWND hLogTitle = CreateWindowExW(0, L"STATIC", L"📋 运行状态与事件日志", WS_CHILD | WS_VISIBLE | SS_LEFT, 20, 205, 200, 20, g_hWnd, NULL, hInstance, NULL);
    SendMessageW(hLogTitle, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);

    HWND hBtnClearLog = CreateWindowExW(0, L"BUTTON", L"清空", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 680, 202, 80, 26, g_hWnd, (HMENU)IDC_BTN_CLEAR_LOG, hInstance, NULL);
    SendMessageW(hBtnClearLog, WM_SETFONT, (WPARAM)g_hFontNormal, TRUE);

    g_hEditLog = CreateWindowExW(
        WS_EX_CLIENTEDGE, L"EDIT", L"",
        WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,
        20, 235, 740, 430,
        g_hWnd, (HMENU)IDC_EDIT_LOG, hInstance, NULL
    );
    SendMessageW(g_hEditLog, WM_SETFONT, (WPARAM)g_hFontMono, TRUE);

    ShowWindow(g_hWnd, SW_SHOW);
    UpdateWindow(g_hWnd);

    // 5. 绑定控制器回调
    auto& ctl = DesktopController::GetInstance();

    ctl.SetLogCallback([](const std::string& line) {
        std::string* p = new std::string(line);
        PostMessage(g_hWnd, WM_ACAST_LOG, 0, (LPARAM)p);
    });

    ctl.SetFastMirrorCallback([](bool connected, const std::string& address) {
        std::string* p = new std::string(address);
        PostMessage(g_hWnd, WM_ACAST_FM_UPDATE, connected ? 1 : 0, (LPARAM)p);
    });

    ctl.SetDiscoveredPhonesCallback([](const std::vector<acast::discovery::DiscoveredPhone>&) {
        PostMessage(g_hWnd, WM_ACAST_PHONE_UPDATE, 0, 0);
    });

    ctl.SetUsbDeviceCallback([](const std::vector<acast::adb::AdbDevice>&) {
        PostMessage(g_hWnd, WM_ACAST_USB_UPDATE, 0, 0);
    });

    ctl.SetUpdateCallback([](const acast::updater::UpdateInfo& info) {
        acast::updater::UpdateInfo* p = new acast::updater::UpdateInfo(info);
        PostMessage(g_hWnd, WM_ACAST_UPDATE_INFO, 0, (LPARAM)p);
    });

    ctl.Init();
    ctl.RefreshPhones();

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    ctl.Cleanup();
    return (int)msg.wParam;
}

} // namespace desktop
} // namespace acast

#endif // _WIN32
