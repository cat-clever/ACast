cmake_minimum_required(VERSION 3.15)
project(acast_desktop VERSION 0.2.3 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(DESKTOP_SOURCES
    src/main.cpp
    src/desktop_controller.cpp
)

# Windows 原生 GUI 配置
if(WIN32)
    list(APPEND DESKTOP_SOURCES
        src/gui_win.cpp
        resources/app.rc
    )
endif()

# macOS 原生 Cocoa GUI 配置
if(APPLE)
    list(APPEND DESKTOP_SOURCES
        src/gui_macos.mm
        resources/acast.icns
    )
endif()

add_executable(acast_desktop ${DESKTOP_SOURCES})

target_link_libraries(acast_desktop PRIVATE acast_core)

# Windows 链接依赖与子系统配置 (无黑框控制台)
if(WIN32)
    set_target_properties(acast_desktop PROPERTIES
        WIN32_EXECUTABLE TRUE
    )
    target_link_libraries(acast_desktop PRIVATE
        ws2_32
        comctl32
        gdi32
        user32
        shell32
    )
endif()

# macOS Bundle 属性与 Cocoa 框架链接
if(APPLE)
    set_target_properties(acast_desktop PROPERTIES
        MACOSX_BUNDLE TRUE
        OUTPUT_NAME "ACast"
        MACOSX_BUNDLE_ICON_FILE "acast.icns"
        MACOSX_BUNDLE_BUNDLE_NAME "ACast"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.catclever.acast"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "0.2.3"
        MACOSX_BUNDLE_BUNDLE_VERSION "0.2.3"
    )

    set_source_files_properties(
        resources/acast.icns
        PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources"
    )

    target_compile_options(acast_desktop PRIVATE "-fobjc-arc")
    target_link_libraries(acast_desktop PRIVATE "-framework Cocoa")
endif()
