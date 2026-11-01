# 通过此文件的位置确定工程根目录；不依赖调用时所在目录。
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

BUILDROOT_VERSION="2026.08.1"
LINUX_VERSION="v6.18.60"
UBOOT_VERSION="v2026.10"

BR_SRC="$PROJECT_ROOT/src/buildroot"
LINUX_SRC="$PROJECT_ROOT/src/linux"
UBOOT_SRC="$PROJECT_ROOT/src/u-boot"

BR_OUT="$PROJECT_ROOT/out/buildroot-$BUILDROOT_VERSION"
LINUX_OUT="$PROJECT_ROOT/out/linux-$LINUX_VERSION"
UBOOT_OUT="$PROJECT_ROOT/out/u-boot-$UBOOT_VERSION"
RUN_DIR="$PROJECT_ROOT/out/run"

CROSS_COMPILE="$BR_OUT/host/bin/aarch64-buildroot-linux-gnu-"
JOBS="${JOBS:-4}"

mkdir -p "$RUN_DIR"
