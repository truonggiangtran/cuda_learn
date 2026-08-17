cmake_minimum_required(VERSION 3.18)

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
if (NOT OpenCV_FOUND)
    message(FATAL_ERROR "OpenCV not found")
endif()
message(STATUS "Found OpenCV version: ${OpenCV_VERSION}")
add_subdirectory(source)
