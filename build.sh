#!/bin/bash
# SDFSpy 一键构建（macOS + Docker 环境）
# 用法: ./build.sh
set -e

IMAGE=xcodeorg/xcode:15.4

docker run --rm -it \
    -v "$(pwd)":/build -w /build \
    "$IMAGE" \
    bash -c '
        set -e
        if [ ! -d /Theos ]; then
            git clone https://github.com/theos/theos.git /Theos --depth=1
        fi
        export THEOS=/Theos
        export THEOS_DEVICE_IP=""
        make clean
        make package
        echo "======================"
        echo "产物: _Packages/arm64/com.ssx.sdfsafari.spy_*.deb"
        echo "======================"
    '
