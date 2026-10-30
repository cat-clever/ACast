cmake_minimum_required(VERSION 3.15)
project(acast_desktop VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(acast_desktop
    src/main.cpp
)

target_link_libraries(acast_desktop PRIVATE acast_core)

# Windows 图标与依赖
if(WIN32)
    target_link_libraries(acast_desktop PRIVATE ws2_32)
endif()

# macOS 属性
if(APPLE)
    set_target_properties(acast_desktop PROPERTIES
        MACOSX_BUNDLE TRUE
        OUTPUT_NAME "ACast"
    )
endif()

