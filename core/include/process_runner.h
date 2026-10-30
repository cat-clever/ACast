#pragma once

#include <string>
#include <vector>
#include <array>
#include <cstdio>
#include <cstdlib>

#if defined(_WIN32)
#include <windows.h>

namespace acast {
namespace process {

// 静默执行命令行并捕获 stdout/stderr 输出 (CREATE_NO_WINDOW + SW_HIDE 杜绝弹出任何黑框终端窗口)
inline std::string RunSilentCapture(const std::string& cmd_utf8) {
    if (cmd_utf8.empty()) return "";

    // 将 UTF-8 命令行转换为宽字符 UTF-16
    int wlen = MultiByteToWideChar(CP_UTF8, 0, cmd_utf8.c_str(), -1, NULL, 0);
    if (wlen <= 0) return "";
    std::wstring cmd_w(wlen, 0);
    MultiByteToWideChar(CP_UTF8, 0, cmd_utf8.c_str(), -1, &cmd_w[0], wlen);

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = NULL;

    HANDLE hReadPipe = NULL;
    HANDLE hWritePipe = NULL;
    if (!CreatePipe(&hReadPipe, &hWritePipe, &sa, 0)) {
        return "";
    }
    SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si = {0};
    si.cb = sizeof(STARTUPINFOW);
    si.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
    si.wShowWindow = SW_HIDE;
    si.hStdOutput = hWritePipe;
    si.hStdError = hWritePipe;
    si.hStdInput = NULL;

    PROCESS_INFORMATION pi = {0};

    // 优先直接作为可执行程序执行
    std::wstring cmdToRun = cmd_w;
    std::vector<wchar_t> cmdBuf(cmdToRun.begin(), cmdToRun.end());
    cmdBuf.push_back(L'\0');

    BOOL success = CreateProcessW(
        NULL,
        cmdBuf.data(),
        NULL,
        NULL,
        TRUE,
        CREATE_NO_WINDOW,
        NULL,
        NULL,
        &si,
        &pi
    );

    if (!success) {
        // 若直接执行失败（如为 shell 内置命令或批处理），通过 cmd.exe /c 静默执行
        std::wstring shellCmd = L"cmd.exe /c " + cmd_w;
        std::vector<wchar_t> shellBuf(shellCmd.begin(), shellCmd.end());
        shellBuf.push_back(L'\0');

        success = CreateProcessW(
            NULL,
            shellBuf.data(),
            NULL,
            NULL,
            TRUE,
            CREATE_NO_WINDOW,
            NULL,
            NULL,
            &si,
            &pi
        );
    }

    CloseHandle(hWritePipe);

    if (!success) {
        CloseHandle(hReadPipe);
        return "";
    }

    std::string output;
    char buffer[1024];
    DWORD bytesRead = 0;
    while (ReadFile(hReadPipe, buffer, sizeof(buffer), &bytesRead, NULL) && bytesRead > 0) {
        output.append(buffer, bytesRead);
    }
    CloseHandle(hReadPipe);

    WaitForSingleObject(pi.hProcess, 15000);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return output;
}

// 静默执行命令 (不需要输出，返回进程退出码，绝对无终端窗口闪烁)
inline int RunSilent(const std::string& cmd_utf8) {
    if (cmd_utf8.empty()) return -1;

    int wlen = MultiByteToWideChar(CP_UTF8, 0, cmd_utf8.c_str(), -1, NULL, 0);
    if (wlen <= 0) return -1;
    std::wstring cmd_w(wlen, 0);
    MultiByteToWideChar(CP_UTF8, 0, cmd_utf8.c_str(), -1, &cmd_w[0], wlen);

    STARTUPINFOW si = {0};
    si.cb = sizeof(STARTUPINFOW);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    PROCESS_INFORMATION pi = {0};

    std::vector<wchar_t> cmdBuf(cmd_w.begin(), cmd_w.end());
    cmdBuf.push_back(L'\0');

    BOOL success = CreateProcessW(
        NULL,
        cmdBuf.data(),
        NULL,
        NULL,
        FALSE,
        CREATE_NO_WINDOW,
        NULL,
        NULL,
        &si,
        &pi
    );

    if (!success) {
        std::wstring shellCmd = L"cmd.exe /c " + cmd_w;
        std::vector<wchar_t> shellBuf(shellCmd.begin(), shellCmd.end());
        shellBuf.push_back(L'\0');

        success = CreateProcessW(
            NULL,
            shellBuf.data(),
            NULL,
            NULL,
            FALSE,
            CREATE_NO_WINDOW,
            NULL,
            NULL,
            &si,
            &pi
        );
    }

    if (!success) return -1;

    WaitForSingleObject(pi.hProcess, 60000);
    DWORD exitCode = 0;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return (int)exitCode;
}

} // namespace process
} // namespace acast

#else // !defined(_WIN32)

namespace acast {
namespace process {

inline std::string RunSilentCapture(const std::string& cmd) {
    std::string result;
    std::array<char, 512> buffer;
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return "";
    while (fgets(buffer.data(), (int)buffer.size(), pipe) != nullptr) {
        result += buffer.data();
    }
    pclose(pipe);
    return result;
}

inline int RunSilent(const std::string& cmd) {
    return std::system(cmd.c_str());
}

} // namespace process
} // namespace acast

#endif

