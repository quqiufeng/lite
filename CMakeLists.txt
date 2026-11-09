cmake_minimum_required(VERSION 3.16)
project(lite_cache C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(OpenMP REQUIRED)
find_package(PkgConfig REQUIRED)
find_package(X11 REQUIRED)
pkg_check_modules(PNG REQUIRED libpng)
pkg_check_modules(JPEG REQUIRED libjpeg)
pkg_check_modules(WEBP REQUIRED libwebp)

add_library(lite_cache SHARED
    src/cache/cache.c
    src/cache/hash_index.c
    src/cache/sorted_array.c
    src/cache/skip_list.c
    src/cache/namespace.c
    src/cache/search.c
    src/cache/iter.c
    src/cache/tag_index.c
    src/cache/index_persistence.c
    src/cache/vector_index.c
    src/cache/hnsw.c
    src/storage/mmap.c
    src/utils/metrics.c
)

target_include_directories(lite_cache PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_options(lite_cache PRIVATE -O2 -Wall -Wextra)
target_link_libraries(lite_cache PRIVATE m OpenMP::OpenMP_C)
set_target_properties(lite_cache PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    OUTPUT_NAME lite_cache)

add_library(lite_image SHARED src/image/image.c)
target_include_directories(lite_image PRIVATE
    ${PNG_INCLUDE_DIRS} ${JPEG_INCLUDE_DIRS} ${WEBP_INCLUDE_DIRS})
target_link_libraries(lite_image PRIVATE
    ${PNG_LIBRARIES} ${JPEG_LIBRARIES} ${WEBP_LIBRARIES} m)
target_compile_options(lite_image PRIVATE -O2 -Wall -Wextra)
set_target_properties(lite_image PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    OUTPUT_NAME lite_image
    BUILD_RPATH "$ORIGIN"
    INSTALL_RPATH "$ORIGIN")

add_library(lite_capture SHARED src/x11/capture.c)
target_include_directories(lite_capture PRIVATE ${X11_INCLUDE_DIR} ${PNG_INCLUDE_DIRS})
target_link_libraries(lite_capture PRIVATE ${X11_LIBRARIES} ${PNG_LIBRARIES} m)
target_compile_options(lite_capture PRIVATE -O2 -Wall -Wextra)
set_target_properties(lite_capture PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    OUTPUT_NAME lite_capture
    BUILD_RPATH "$ORIGIN"
    INSTALL_RPATH "$ORIGIN")

add_library(lite_html SHARED src/html/render.cpp)
target_include_directories(lite_html PRIVATE /opt/litehtml/include)
target_link_libraries(lite_html PRIVATE /opt/litehtml/build-pic/liblitehtml.so cairo fontconfig)
target_compile_options(lite_html PRIVATE -O2 -Wall)
set_target_properties(lite_html PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    OUTPUT_NAME lite_html
    BUILD_RPATH "$ORIGIN;/opt/litehtml/build-pic"
    INSTALL_RPATH "${CMAKE_BINARY_DIR}")
