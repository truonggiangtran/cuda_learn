add_subdirectory(image_processing)

add_executable(main
    main.cpp
)

target_link_libraries(main PRIVATE
    image_processing
)

if(GPU_NPU_PLATFORM_WINDOWS)
    target_link_libraries(main PRIVATE
        windowscodecs
        ole32
        shell32
    )
elseif(GPU_NPU_PLATFORM_LINUX)
    target_link_libraries(main PRIVATE
        ${OpenCV_LIBS}
    )
endif()

if(MSVC AND ENABLE_MSVC_DEBUG)
    target_compile_definitions(main PRIVATE
        $<$<CONFIG:Debug>:GPU_NPU_DEBUG=1>
    )

    target_compile_options(main PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:$<$<CONFIG:Debug>:/Zi /Od /RTC1>>
    )

    target_link_options(main PRIVATE
        $<$<CONFIG:Debug>:/DEBUG:FULL /INCREMENTAL>
    )
endif()
