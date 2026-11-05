#!/usr/bin/env bash
# lite 编译发布：build + package + install（默认 /usr/local/bin）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
INSTALL=1

while [ $# -gt 0 ]; do
    case "$1" in
        --no-install)
            INSTALL=0
            shift
            ;;
        --prefix)
            PREFIX="${2:?--prefix requires a value}"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            shift
            ;;
        -h|--help)
            cat <<EOF
usage: tools/release.sh [--no-install] [--prefix <dir>]

  build + package + install lite to <prefix>/bin
  default prefix: /usr/local  (auto sudo when needed)

  --no-install      only build and package
  --prefix DIR      install prefix (default: \$PREFIX or /usr/local)
EOF
            exit 0
            ;;
        *)
            echo "release: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

"$ROOT/tools/build.sh"
"$ROOT/tools/package.sh"

if [ "$INSTALL" -eq 0 ]; then
    echo "package only: $ROOT/dist/lite-linux-x64.tar.gz"
    exit 0
fi

mkdir -p "$PREFIX/bin" 2>/dev/null || true

if [ "$(id -u)" -eq 0 ] || [ -w "$PREFIX/bin" ]; then
    PREFIX="$PREFIX" "$ROOT/tools/install.sh"
else
    if ! command -v sudo >/dev/null 2>&1; then
        echo "release: $PREFIX/bin is not writable and sudo is missing" >&2
        exit 1
    fi
    sudo env PREFIX="$PREFIX" "$ROOT/tools/install.sh"
fi

echo "installed: $PREFIX/bin/lite"
"$PREFIX/bin/lite" --version
