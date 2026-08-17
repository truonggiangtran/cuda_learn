add_subdirectory(image_processing)
add_subdirectory(matrix)
if(BUILD_CAMERA_CONTROL)
    add_subdirectory(camera_control)
endif()

add_executable(main
    main.cpp
)

target_link_libraries(main PRIVATE
    image_processing
    matrix
)

target_link_libraries(main PRIVATE
    ${OpenCV_LIBS}
)

install(TARGETS main
    RUNTIME DESTINATION bin
)
