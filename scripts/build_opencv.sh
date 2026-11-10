#!/bin/sh
# 编译 Touch SD App 用的 OpenCV 5.0.0 静态库（指纹比对是按这个版本调的）。
# 只编 core / imgproc / features / geometry / flann / video（ECC 精配准），arm64 和 x86_64 各编一次再 lipo 成通用库，
# 结果在 vendor/opencv/{include,lib}。vendor/ 不进 git，换机器重新跑本脚本即可（约 5–10 分钟）。
set -e
cd "$(dirname "$0")/.."
VER=5.0.0
V=vendor
# 需要 cmake 和 ninja（brew install cmake ninja），也可以用 CMAKE=... NINJA=... 指定
CMAKE=${CMAKE:-$(command -v cmake || true)}
NINJA=${NINJA:-$(command -v ninja || true)}
[ -n "$CMAKE" ] && [ -n "$NINJA" ] || { echo "找不到 cmake 或 ninja：brew install cmake ninja"; exit 1; }
mkdir -p "$V"
[ -d "$V/opencv-$VER" ] || {
    curl -sL -o "$V/opencv-$VER.tar.gz" "https://github.com/opencv/opencv/archive/refs/tags/$VER.tar.gz"
    tar xzf "$V/opencv-$VER.tar.gz" -C "$V"
}
# arm64 和 opencv-python 轮子同配置（KleidiCV + carotene HAL、Accelerate 的 LAPACK、
# GCD 并行），比对结果才能逐位对上。x86_64 要显式说目标处理器，否则 CMake 按主机（Apple 芯片）
# 判断，把 ARM 专用的 KleidiCV/carotene 也编进来；Intel 上没有这两个 HAL，结果可能有极小差别。
for ARCH in arm64 x86_64; do
    B="$V/build-$ARCH"
    if [ $ARCH = x86_64 ]; then
        EXTRA="-DCMAKE_SYSTEM_PROCESSOR=x86_64 -DWITH_KLEIDICV=OFF -DWITH_CAROTENE=OFF"
    else
        EXTRA=""
    fi
    "$CMAKE" -S "$V/opencv-$VER" -B "$B" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" $EXTRA \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
        -DCMAKE_INSTALL_PREFIX="$PWD/$V/install-$ARCH" \
        -DBUILD_LIST=core,imgproc,features,geometry,flann,video \
        -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF \
        -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF -DBUILD_opencv_python3=OFF \
        -DWITH_IPP=OFF -DWITH_ITT=OFF -DWITH_OPENCL=OFF -DWITH_EIGEN=OFF \
        -DWITH_PROTOBUF=OFF -DWITH_OPENVINO=OFF -DWITH_ADE=OFF -DWITH_FFMPEG=OFF \
        -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF -DWITH_OPENJPEG=OFF \
        -DWITH_OPENEXR=OFF -DWITH_AVIF=OFF -DWITH_JASPER=OFF -DWITH_IMGCODEC_HDR=OFF \
        -DCV_TRACE=OFF -DOPENCV_GENERATE_PKGCONFIG=OFF > "$V/cmake-$ARCH.log"
    "$CMAKE" --build "$B" --target install > "$V/build-$ARCH.log"
done
# 合成通用库
OUT="$V/opencv"
rm -rf "$OUT" && mkdir -p "$OUT/lib"
cp -R "$V/install-arm64/include" "$OUT/include"
for A in $(cd "$V/install-arm64" && find lib -name '*.a'); do
    if [ -f "$V/install-x86_64/$A" ]; then
        lipo -create "$V/install-arm64/$A" "$V/install-x86_64/$A" -output "$OUT/lib/$(basename "$A")"
    else
        # KleidiCV / carotene 只有 arm64；x86_64 链接时会提示忽略它们，不影响
        cp "$V/install-arm64/$A" "$OUT/lib/$(basename "$A")"
    fi
done
ls "$OUT/lib"
