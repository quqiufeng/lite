#!/usr/bin/env bash
# dist 产物的架构后缀，被 package.sh / install.sh / release.sh source。
#
# 为什么不是直接用 `uname -m`：产物名一直是 `lite-linux-x64`，写成 `lite-linux-x86_64`
# 会让既有 dist/ 目录、README 里的路径、以及按名字找包的人全部对不上。所以统一映射一次。
#
# 为什么单独成文件：三处脚本必须算出同一个名字，否则 package 打 arm64 包、install 找
# x64 包，release 一路跑到 install 才炸。复制三份迟早改漏一处。
#
# 交叉编译时宿主 arch ≠ 目标 arch，用 LITE_DIST_ARCH 覆盖：
#   LITE_DIST_ARCH=arm64 ./tools/package.sh

_lite_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo x64 ;;
        aarch64|arm64)  echo arm64 ;;
        armv7l|armv7)   echo armv7 ;;
        armv6l|armv6)   echo armv6 ;;
        *)              uname -m ;;
    esac
}

LITE_DIST_ARCH="${LITE_DIST_ARCH:-$(_lite_arch)}"
LITE_DIST_NAME="lite-linux-${LITE_DIST_ARCH}"
