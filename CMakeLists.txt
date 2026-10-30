cmake_minimum_required(VERSION 3.15)
project(ACast VERSION 0.3.3 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 全局强制 MSVC 使用 UTF-8 源码与执行字符集，彻底杜绝 Windows 界面乱码
if(MSVC)
    add_compile_options(/utf-8)
endif()

if(APPLE)
    enable_language(OBJCXX)
endif()

# macOS Universal 2 架构支持
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "x86_64;arm64" CACHE STRING "Build universal binary for macOS" FORCE)
endif()

add_subdirectory(core)
add_subdirectory(app-desktop)

