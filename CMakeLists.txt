cmake_minimum_required(VERSION 3.16)
project(lite_cache C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(OpenMP REQUIRED)

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
