cmake_minimum_required(VERSION 3.15)
project(ACast VERSION 0.5.7 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 全局统一定义项目版本宏，彻底杜绝 C++ 控制端硬编码版本滞后问题
add_compile_definitions(ACAST_VERSION_STRING="${PROJECT_VERSION}")

# 全局强制 MSVC 使用 UTF-8 源码与执行字符集，彻底杜绝 Windows 界面乱码
if(MSVC)
    add_compile_options(/utf-8)
endif()

# macOS 平台全局构建配置
if(APPLE)
    enable_language(OBJCXX)
    # 全局强制最低部署版本为 macOS 11.0 (Big Sur)，彻底根除 CI Runner 导致 minos=26.0 无法在用户 Mac 运行的严重问题
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS deployment version" FORCE)
    endif()
    add_compile_options(-mmacosx-version-min=11.0)
    add_link_options(-mmacosx-version-min=11.0)
endif()

# macOS Universal 2 架构支持
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "x86_64;arm64" CACHE STRING "Build universal binary for macOS" FORCE)
endif()

add_subdirectory(core)
add_subdirectory(app-desktop)

