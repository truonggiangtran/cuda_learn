add_subdirectory(image_processing)

add_executable(main
    main.cpp
)

target_link_libraries(main PRIVATE
    image_processing
)

target_link_libraries(main PRIVATE
    ${OpenCV_LIBS}
)

install(TARGETS main
    RUNTIME DESTINATION bin
)
