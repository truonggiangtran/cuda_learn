add_subdirectory(image_processing)

add_executable(main
    main.cpp
)

add_executable(cuda_benchmark
    benchmark_main.cpp
)

target_link_libraries(main PRIVATE
    image_processing
)

target_link_libraries(cuda_benchmark PRIVATE
    image_processing
)

target_link_libraries(main PRIVATE
    ${OpenCV_LIBS}
)

install(TARGETS main
    RUNTIME DESTINATION bin
)

install(TARGETS cuda_benchmark
    RUNTIME DESTINATION bin
)
