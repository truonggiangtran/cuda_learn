cmake_minimum_required(VERSION 3.18)

# This project uses vcpkg to manage dependencies. If you have not already done so, please install vcpkg and integrate it with CMake:
#print VCPKG_ROOT and CMAKE_TOOLCHAIN_FILE to help users debug issues with vcpkg integration.
message(STATUS "VCPKG_ROOT: $ENV{VCPKG_ROOT}")
message(STATUS "CMAKE_TOOLCHAIN_FILE: ${CMAKE_TOOLCHAIN_FILE}")

if(DEFINED ENV{VCPKG_ROOT} AND NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_TOOLCHAIN_FILE
        "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
        CACHE FILEPATH "Path to the vcpkg toolchain file"
    )
endif()

project(gpu_npu LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

option(ENABLE_MSVC_DEBUG "Enable extra MSVC/CUDA debug flags for Debug config" ON)
option(ENABLE_BLACKWELL_ARCH "Build CUDA kernels for Blackwell GPUs (sm_120)" ON)

find_package(CUDAToolkit REQUIRED)
find_package(OpenCV REQUIRED)

add_subdirectory(source)
