#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
. "$PROJECT_ROOT/env.sh"

mode="${1:-linux}"
case "$mode" in
  linux|uboot) ;;
  *) echo "usage: $0 [linux|uboot]" >&2; exit 2 ;;
esac

qemu=(qemu-system-aarch64
  -machine virt -cpu cortex-a53 -smp 1 -m 1G -accel tcg
  -drive "if=none,file=$BR_OUT/images/rootfs.ext4,format=raw,id=rootfs"
  -device virtio-blk-device,drive=rootfs
  -netdev user,id=net0 -device virtio-net-device,netdev=net0
  -nographic -snapshot)

if [[ "$mode" == linux ]]; then
  qemu+=(-kernel "$LINUX_OUT/arch/arm64/boot/Image"
    -append 'console=ttyAMA0 root=/dev/vda rw rootwait nokaslr')
else
  # Image 与 DTB 的预加载区间不能重叠；大内核需重新规划地址。
  image_size=$(stat -c %s "$LINUX_OUT/arch/arm64/boot/Image")
  if (( image_size >= 112 * 1024 * 1024 )); then
    echo 'Image >= 112 MiB：请先调整 Image/DTB 加载地址及 booti 参数。' >&2
    exit 1
  fi
  # 生成与正式运行完全相同拓扑（含 U-Boot firmware）的 DTB；不传调试参数。
  qemu-system-aarch64 \
    -machine "virt,dumpdtb=$RUN_DIR/virt.dtb" \
    -cpu cortex-a53 -smp 1 -m 1G -accel tcg \
    -bios "$UBOOT_OUT/u-boot.bin" \
    -drive "if=none,file=$BR_OUT/images/rootfs.ext4,format=raw,id=rootfs" \
    -device virtio-blk-device,drive=rootfs \
    -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
    -nographic -snapshot
  test -s "$RUN_DIR/virt.dtb"
  qemu+=(-bios "$UBOOT_OUT/u-boot.bin"
    -device "loader,file=$LINUX_OUT/arch/arm64/boot/Image,addr=0x48000000,force-raw=on"
    -device "loader,file=$RUN_DIR/virt.dtb,addr=0x4f000000,force-raw=on")
fi

if [[ "${DEBUG:-0}" == 1 ]]; then
  qemu+=(-S -gdb tcp:127.0.0.1:1234)
fi
exec "${qemu[@]}"
