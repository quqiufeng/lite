cmake_minimum_required(VERSION 3.16)
project(lite_cache C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# macOS（Darwin）上三个 Linux 假设都不成立：没有 OpenMP（Apple clang 不带 libomp）、
# 没有 X11（要额外装 XQuartz，且 src/x11/capture.c 是 XGetImage/XOpenDisplay 实现）、
# litehtml 编出来是 .dylib 不是 .so。所以 APPLE 分支降级而不报错：OpenMP 缺了少并行，
# X11 缺了不建 lite_capture（截图/点击是 X11 专属能力，Lua 侧 libfind 找不到会自行回退），
# litehtml 不存在就跳过 lite_html。**Linux 分支保持原样**：仍全部 REQUIRED。
if(APPLE)
    find_package(OpenMP QUIET)
else()
    find_package(OpenMP REQUIRED)
endif()
find_package(PkgConfig REQUIRED)
pkg_check_modules(PNG REQUIRED libpng)
pkg_check_modules(JPEG REQUIRED libjpeg)
pkg_check_modules(WEBP REQUIRED libwebp)

# OpenMP 可能缺席（macOS 常见），缺席时构造空列表，链接行不出现 OpenMP::OpenMP_C。
set(LITE_OMP_LIBS "")
if(TARGET OpenMP::OpenMP_C)
    list(APPEND LITE_OMP_LIBS OpenMP::OpenMP_C)
endif()

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
target_link_libraries(lite_cache PRIVATE m ${LITE_OMP_LIBS})
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

# TUI 文本内核（宽度/折行/cell/行内 diff）：纯 C，无外部依赖。
# 对应 lua/ffi/tui.lua；找不到时 Lua 侧自动回退纯 Lua 实现。
add_library(lite_tui SHARED src/tui/text.c)
target_compile_options(lite_tui PRIVATE -O2 -Wall -Wextra)
set_target_properties(lite_tui PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    OUTPUT_NAME lite_tui
    BUILD_RPATH "$ORIGIN"
    INSTALL_RPATH "$ORIGIN")

# 截图/点击内核是 X11 实现（XGetImage + XShm），macOS 上没有 X11 的等价物——
# 要么装 XQuartz（不是原生 Wayland/Quartz 路径，抓不到别的 app），要么写 CoreGraphics 后端。
# 现在只在「真的有 X11」时建它；缺席就跳过，Lua 侧 lua/ffi/capture.lua 加载失败会自行降级。
if(APPLE)
    find_package(X11 QUIET)
else()
    find_package(X11 REQUIRED)
endif()

if(X11_FOUND)
add_library(lite_capture SHARED src/x11/capture.c)
target_include_directories(lite_capture PRIVATE ${X11_INCLUDE_DIR} ${PNG_INCLUDE_DIRS})
target_link_libraries(lite_capture PRIVATE ${X11_LIBRARIES} ${PNG_LIBRARIES} m)
target_compile_options(lite_capture PRIVATE -O2 -Wall -Wextra)
set_target_properties(lite_capture PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    OUTPUT_NAME lite_capture
    BUILD_RPATH "$ORIGIN"
    INSTALL_RPATH "$ORIGIN")
else()
    message(STATUS "lite_capture disabled: 没有 X11（macOS 上截图/点击需要 CoreGraphics 后端）")
endif()

# litehtml 装在哪可覆盖：交叉编译时指向 sysroot 里的副本
# （--sysroot 只改编译器默认搜索路径，不会改写写死的绝对路径）。
set(LITEHTML_ROOT "/opt/litehtml" CACHE PATH "litehtml 安装根目录（含 include/ 与 build-pic/）")
# litehtml 本体是外部依赖（本机 /opt/litehtml），不是每家都有：macOS 上按 .dylib 找，
# 找不到就跳过 lite_html（md2png/pdf/web2png 出图能力缺席，其余功能照常）。
if(APPLE)
    set(_LITEHTML_LIB "${LITEHTML_ROOT}/build-pic/liblitehtml.dylib")
else()
    set(_LITEHTML_LIB "${LITEHTML_ROOT}/build-pic/liblitehtml.so")
endif()
if(EXISTS "${_LITEHTML_LIB}")
add_library(lite_html SHARED src/html/render.cpp src/html/prepass.cpp src/html/imgcache.cpp)
target_include_directories(lite_html PRIVATE ${LITEHTML_ROOT}/include
    ${PNG_INCLUDE_DIRS} ${JPEG_INCLUDE_DIRS} ${WEBP_INCLUDE_DIRS})
target_link_libraries(lite_html PRIVATE ${_LITEHTML_LIB} cairo fontconfig
    ${PNG_LIBRARIES} ${JPEG_LIBRARIES} ${WEBP_LIBRARIES})
# libgumbo 升成 liblite_html.so 的直接 NEEDED。原因：liblitehtml.so.0 自己声明的
# RUNPATH 是绝对值 /opt/litehtml/build-pic/src/gumbo，目标机没这目录时 dlopen 链会在
# 它的依赖上断掉（liblitehtml 找到、libgumbo 找不到），随包的 .so 于是不自洽。
# 直接 NEEDED 后 $ORIGIN 生效，三个 .so 摆同一目录即可自解析。
# --no-as-needed 必需：render.cpp 不直接引用 gumbo 符号，默认 --as-needed 会把它丢掉。
set(LITEHTML_GUMBO_DIR "${LITEHTML_ROOT}/build-pic/src/gumbo" CACHE PATH
    "Directory containing libgumbo.so.0 (litehtml's HTML parser)")
set(LITE_HTML_GUMBO "${LITEHTML_GUMBO_DIR}")
if(APPLE)
    set(_LITE_GUMBO_SO "${LITE_HTML_GUMBO}/libgumbo.0.dylib")
else()
    set(_LITE_GUMBO_SO "${LITE_HTML_GUMBO}/libgumbo.so.0")
endif()
if(EXISTS "${_LITE_GUMBO_SO}")
    # macOS 的 ld 不认 --no-as-needed/--as-needed（无对应的 dylib 死剥问题），只 Linux 加。
    if(APPLE)
        target_link_libraries(lite_html PRIVATE "${_LITE_GUMBO_SO}")
    else()
        target_link_libraries(lite_html PRIVATE
            "-Wl,--no-as-needed" "${_LITE_GUMBO_SO}" "-Wl,--as-needed")
    endif()
    message(STATUS "lite_html: 直接链接 ${_LITE_GUMBO_SO}（随包自解析）")
endif()
target_compile_options(lite_html PRIVATE -O2 -Wall)
set_target_properties(lite_html PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    OUTPUT_NAME lite_html
    BUILD_RPATH "$ORIGIN;/opt/litehtml/build-pic"
    INSTALL_RPATH "$ORIGIN")
else()
    message(STATUS "lite_html disabled: 没找到 ${_LITEHTML_LIB}（md2png/pdf/web2png 出图能力缺席）")
endif()

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

if(EXISTS "${LITE_CS_TOKENIZERS_DIR}/libtokenizers_c.a" AND LITE_CS_JANSSON_LIB AND NOT APPLE)
# NOT APPLE：仓库自带的 libtokenizers_c.a 等是 Linux x86_64 目标文件，macOS 上链接必炸
# （架构不符），且下面用的是 GNU ld 的 -Wl,--start-group。缺它只是少 lite_codesearch，
# 词法/符号/上下文查询仍走 lite_cache + helper。
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
