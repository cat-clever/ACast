cmake_minimum_required(VERSION 3.15)
project(acast_core VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(include)

set(CORE_SOURCES
    src/fastmirror_protocol.cpp
    src/dlna_controller.cpp
    src/http_ts_server.cpp
    src/adb_tunnel.cpp
)

set(CORE_HEADERS
    include/fastmirror_protocol.h
    include/dlna_controller.h
    include/http_ts_server.h
    include/adb_tunnel.h
)

add_library(acast_core STATIC ${CORE_SOURCES} ${CORE_HEADERS})

target_include_directories(acast_core PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)

if(WIN32)
    target_link_libraries(acast_core PUBLIC ws2_32)
else()
    target_link_libraries(acast_core PUBLIC pthread)
endif()
