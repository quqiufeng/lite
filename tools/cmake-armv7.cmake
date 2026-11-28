# lite 交叉编译工具链：x86_64 宿主 → armv7（32 位）目标。**未在真机实测，[static] 推演**。
# 与 cmake-aarch64.cmake 逐行同构，只换了工具链前缀与 processor 名；用法一致。
#
# 为什么要 sysroot：`arm-linux-gnueabihf-gcc` 只提供 libc 与 crt（libc6-dev-arm64-cross），
# cairo/libpng/libjpeg/libwebp/libX11/litehtml 这些一个都没有。目标机的头文件与 .so
# 必须整棵搬来，否则 pkg-config 会安静地命中本机 x86 的那份（-L/usr/lib/x86_64-linux-gnu），
# 链接成功、产物却是坏的 —— 这是交叉编译最典型的「绿着炸」。
#
# sysroot 用环境变量 LITE_SYSROOT 指定（默认 ~/arm64-sysroot），结构照抄目标机：
#   $LITE_SYSROOT/usr/include                      ← 目标机 /usr/include
#   $LITE_SYSROOT/usr/lib/arm-linux-gnueabihf        ← 目标机 /usr/lib/arm-linux-gnueabihf
#   $LITE_SYSROOT/lib/arm-linux-gnueabihf            ← 目标机 /lib/arm-linux-gnueabihf（ld.so、libc）
#   $LITE_SYSROOT/opt/litehtml                     ← 目标机 /opt/litehtml（自己编的私有库）
# 生产 sysroot 的办法见 README「交叉编译」：从已装好依赖的目标机 rsync 回来最省事。
#
# 用法（不要直接 cmake，走 tools/cross.sh，它会设好 pkg-config 与 BUILD_DIR）：
#   cmake -S . -B build-arm64 -DCMAKE_TOOLCHAIN_FILE=tools/cmake-aarch64.cmake

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

if(DEFINED ENV{LITE_SYSROOT} AND NOT "$ENV{LITE_SYSROOT}" STREQUAL "")
    set(CMAKE_SYSROOT "$ENV{LITE_SYSROOT}")
elseif(DEFINED ENV{HOME})
    set(CMAKE_SYSROOT "$ENV{HOME}/arm64-sysroot")
endif()

if(NOT EXISTS "${CMAKE_SYSROOT}/usr/lib/arm-linux-gnueabihf")
    message(FATAL_ERROR
        "LITE_SYSROOT 不可用：'${CMAKE_SYSROOT}' 里没有 usr/lib/arm-linux-gnueabihf。\n"
        "先造 sysroot（README「交叉编译」），或 export LITE_SYSROOT=/path/to/sysroot。")
endif()

set(CMAKE_C_COMPILER   arm-linux-gnueabihf-gcc)
set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)
set(CMAKE_AR           arm-linux-gnueabihf-ar CACHE FILEPATH "")
set(CMAKE_RANLIB       arm-linux-gnueabihf-ranlib CACHE FILEPATH "")
set(CMAKE_STRIP        arm-linux-gnueabihf-strip CACHE FILEPATH "")

# find_* 只许在 sysroot 里找：否则 find_package(X11)、find_library(jansson) 会
# 命中宿主的 x86 库，链接期不报错、运行期在目标机 exec format error。
set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# pkg-config 的 .pc 里是目标机的绝对路径（prefix=/usr），靠这个前缀改写到 sysroot 下。
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${CMAKE_SYSROOT}")
set(ENV{PKG_CONFIG_LIBDIR}
    "${CMAKE_SYSROOT}/usr/lib/arm-linux-gnueabihf/pkgconfig:${CMAKE_SYSROOT}/usr/share/pkgconfig")
