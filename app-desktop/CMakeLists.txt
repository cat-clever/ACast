cmake_minimum_required(VERSION 3.15)
project(acast_desktop VERSION 0.1.7 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(acast_desktop
    src/main.cpp
)

target_link_libraries(acast_desktop PRIVATE acast_core)

# Windows 图标与依赖
if(WIN32)
    target_sources(acast_desktop PRIVATE resources/app.rc)
    target_link_libraries(acast_desktop PRIVATE ws2_32)
endif()

# macOS 属性
if(APPLE)
    set(MACOSX_BUNDLE_ICON_FILE "acast.icns")
    set(MACOSX_BUNDLE_BUNDLE_NAME "ACast")
    set(MACOSX_BUNDLE_GUI_IDENTIFIER "com.catclever.acast")
    set(MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.7")
    set(MACOSX_BUNDLE_BUNDLE_VERSION "0.1.7")

    set_source_files_properties(
        resources/acast.icns
        PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources"
    )

    target_sources(acast_desktop PRIVATE resources/acast.icns)

    set_target_properties(acast_desktop PROPERTIES
        MACOSX_BUNDLE TRUE
        OUTPUT_NAME "ACast"
    )
endif()

