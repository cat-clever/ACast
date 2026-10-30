#include "gui_interface.h"

#if defined(_WIN32)
#include <windows.h>

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, PWSTR pCmdLine, int nCmdShow) {
    return acast::desktop::RunDesktopApp(0, nullptr);
}

int main(int argc, char* argv[]) {
    return acast::desktop::RunDesktopApp(argc, argv);
}

#else

int main(int argc, char* argv[]) {
    return acast::desktop::RunDesktopApp(argc, argv);
}

#endif
