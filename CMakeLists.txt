cmake_minimum_required(VERSION 3.18)
project(gpu_npu LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)

option(ENABLE_MSVC_DEBUG "Enable extra MSVC/CUDA debug flags for Debug config" ON)
option(ENABLE_BLACKWELL_ARCH "Build CUDA kernels for Blackwell GPUs (sm_120)" ON)

find_package(CUDAToolkit REQUIRED)

add_executable(main
    image_processing.cu
    main.cpp
)

if(ENABLE_BLACKWELL_ARCH)
    # Blackwell datacenter architecture (sm_120).
    set_target_properties(main PROPERTIES CUDA_ARCHITECTURES "120")
endif()

target_include_directories(main PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(main PRIVATE
    CUDA::cudart
)

if(MSVC AND ENABLE_MSVC_DEBUG)
    target_compile_definitions(main PRIVATE
        $<$<CONFIG:Debug>:GPU_NPU_DEBUG=1>
    )

    target_compile_options(main PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:$<$<CONFIG:Debug>:/Zi /Od /RTC1>>
        $<$<COMPILE_LANGUAGE:CUDA>:$<$<CONFIG:Debug>:-G>>
        $<$<COMPILE_LANGUAGE:CUDA>:$<$<CONFIG:RelWithDebInfo,Release>:-lineinfo>>
    )

    target_link_options(main PRIVATE
        $<$<CONFIG:Debug>:/DEBUG:FULL /INCREMENTAL>
    )
endif()

set_target_properties(main PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
)
