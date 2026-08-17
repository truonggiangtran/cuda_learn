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

project(gpu LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

option(BUILD_CAMERA_CONTROL "Build the optional OpenCV camera wrapper" OFF)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "Unsupported platform: ${CMAKE_SYSTEM_NAME}. Only Linux is supported.")
endif()
message(STATUS "Configuring Linux build")

find_package(CUDAToolkit REQUIRED)
set(GPU_OPENCV_COMPONENTS imgcodecs imgproc)
if(BUILD_CAMERA_CONTROL)
    list(APPEND GPU_OPENCV_COMPONENTS videoio)
endif()

find_package(OpenCV QUIET COMPONENTS ${GPU_OPENCV_COMPONENTS})

if(NOT OpenCV_FOUND AND DEFINED VCPKG_INSTALLED_DIR)
    find_package(OpenCV REQUIRED COMPONENTS ${GPU_OPENCV_COMPONENTS} CONFIG
        PATHS "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/share/opencv4"
        NO_DEFAULT_PATH
    )
elseif(NOT OpenCV_FOUND)
    message(FATAL_ERROR "OpenCV components ${GPU_OPENCV_COMPONENTS} are required.")
endif()

add_subdirectory(source)
