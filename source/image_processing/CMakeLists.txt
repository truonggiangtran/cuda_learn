add_library(image_processing STATIC
    image_processing.cu
)

target_include_directories(image_processing PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(image_processing PUBLIC
    CUDA::cudart
)

if(ENABLE_BLACKWELL_ARCH)
    set_target_properties(image_processing PROPERTIES
        CUDA_ARCHITECTURES "120"
    )
endif()

set_target_properties(image_processing PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_RESOLVE_DEVICE_SYMBOLS ON
)
