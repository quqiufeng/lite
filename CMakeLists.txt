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

add_library(lite_html SHARED src/html/render.cpp src/html/prepass.cpp)
target_include_directories(lite_html PRIVATE /opt/litehtml/include)
target_link_libraries(lite_html PRIVATE /opt/litehtml/build-pic/liblitehtml.so cairo fontconfig)
# libgumbo 升成 liblite_html.so 的直接 NEEDED。原因：liblitehtml.so.0 自己声明的
# RUNPATH 是绝对值 /opt/litehtml/build-pic/src/gumbo，目标机没这目录时 dlopen 链会在
# 它的依赖上断掉（liblitehtml 找到、libgumbo 找不到），随包的 .so 于是不自洽。
# 直接 NEEDED 后 $ORIGIN 生效，三个 .so 摆同一目录即可自解析。
# --no-as-needed 必需：render.cpp 不直接引用 gumbo 符号，默认 --as-needed 会把它丢掉。
set(LITEHTML_GUMBO_DIR "/opt/litehtml/build-pic/src/gumbo" CACHE PATH
    "Directory containing libgumbo.so.0 (litehtml's HTML parser)")
set(LITE_HTML_GUMBO "${LITEHTML_GUMBO_DIR}")
if(EXISTS "${LITE_HTML_GUMBO}/libgumbo.so.0")
    target_link_libraries(lite_html PRIVATE
        "-Wl,--no-as-needed" "${LITE_HTML_GUMBO}/libgumbo.so.0" "-Wl,--as-needed")
    message(STATUS "lite_html: 直接链接 ${LITE_HTML_GUMBO}/libgumbo.so.0（随包自解析）")
endif()
target_compile_options(lite_html PRIVATE -O2 -Wall)
set_target_properties(lite_html PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    OUTPUT_NAME lite_html
    BUILD_RPATH "$ORIGIN;/opt/litehtml/build-pic"
    INSTALL_RPATH "$ORIGIN")

# ---------------- codesearch（从 /opt/my_db 迁移） ----------------
# 语义搜索需要 tokenizers-cpp 静态库与 ONNX Runtime（运行期 dlopen）。
# 默认路径可用 -DLITE_CS_TOKENIZERS_DIR=... 覆盖；找不到就跳过该 target，
# 词法/符号/上下文查询仍可由 lite_cache + helper 提供。
set(_LITE_CS_TOK_LOCAL "${CMAKE_CURRENT_SOURCE_DIR}/third_party/codesearch/lib/tokenizers-cpp")
set(LITE_CS_TOKENIZERS_DIR "${_LITE_CS_TOK_LOCAL}" CACHE PATH
    "Directory containing libtokenizers_c.a and friends")
# 旧 cache 可能还指向 /opt/my_db；仓库已自带静态库，自动切回本地。
if(LITE_CS_TOKENIZERS_DIR STREQUAL "/opt/my_db/lib/tokenizers-cpp"
   AND EXISTS "${_LITE_CS_TOK_LOCAL}/libtokenizers_c.a")
    set(LITE_CS_TOKENIZERS_DIR "${_LITE_CS_TOK_LOCAL}" CACHE PATH
        "Directory containing libtokenizers_c.a and friends" FORCE)
endif()
set(LITE_CS_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/codesearch/include")
find_path(LITE_CS_JANSSON_INCLUDE jansson.h)
find_library(LITE_CS_JANSSON_LIB jansson)

if(EXISTS "${LITE_CS_TOKENIZERS_DIR}/libtokenizers_c.a" AND LITE_CS_JANSSON_LIB)
    add_library(lite_codesearch SHARED
        src/codesearch/api.c
        src/codesearch/indexer.c
        src/codesearch/embedder.c
        src/codesearch/vector_engine.c
        src/codesearch/batch_embedder.c
        src/codesearch/word_freq.c
        src/codesearch/callgraph.c
        src/codesearch/dataflow.c
        src/codesearch/import.c
        src/codesearch/query.c
        src/codesearch/hnsw_build.c
    )
    target_include_directories(lite_codesearch PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/src/codesearch
        ${LITE_CS_INCLUDE_DIR}
        ${LITE_CS_TOKENIZERS_DIR}
        ${LITE_CS_JANSSON_INCLUDE}
    )
    target_compile_definitions(lite_codesearch PRIVATE LITE_CS_HAVE_EMBED=1)
    target_compile_options(lite_codesearch PRIVATE -O2 -Wall -Wextra)
    target_link_libraries(lite_codesearch PRIVATE
        lite_cache
        ${LITE_CS_JANSSON_LIB}
        m
        dl
        pthread
        -Wl,--start-group
        ${LITE_CS_TOKENIZERS_DIR}/libtokenizers_c.a
        ${LITE_CS_TOKENIZERS_DIR}/libtokenizers_cpp.a
        ${LITE_CS_TOKENIZERS_DIR}/libsentencepiece.a
        ${LITE_CS_TOKENIZERS_DIR}/libonig.a
        -Wl,--end-group
    )
    set_target_properties(lite_codesearch PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
        OUTPUT_NAME lite_codesearch
        LINKER_LANGUAGE CXX
        BUILD_RPATH "$ORIGIN"
        INSTALL_RPATH "$ORIGIN")
else()
    message(STATUS "lite_codesearch disabled: tokenizers static lib or jansson not found")
endif()
