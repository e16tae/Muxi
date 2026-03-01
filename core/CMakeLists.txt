cmake_minimum_required(VERSION 3.18)
project(muxi_core C)

# ── Skeleton for Android NDK build ──────────────────────────────────
# This CMakeLists.txt is consumed by the Android Gradle plugin via
# externalNativeBuild { cmake { path "../../core/CMakeLists.txt" } }
#
# For iOS, the C sources are compiled through the MuxiCore SPM package.

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# VT Parser library
add_library(vt_parser STATIC
    vt_parser/vt_parser.c
)
target_include_directories(vt_parser PUBLIC
    vt_parser/include
)

# Tmux Protocol library
add_library(tmux_protocol STATIC
    tmux_protocol/tmux_protocol.c
)
target_include_directories(tmux_protocol PUBLIC
    tmux_protocol/include
)
