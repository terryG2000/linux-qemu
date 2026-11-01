# QEMU + U-Boot + Linux + Buildroot：ARM64 可重复搭建指南

本文从 Ubuntu 主机开始，逐步构建一个可在 QEMU `virt` 机器上运行的 ARM64 Linux 教学系统。重点是把源码、配置和构建产物分开管理，使 Linux 和 U-Boot 能分别升级、测试和回退。

> **固定教学基线**：Ubuntu 22.04/24.04 x86_64；QEMU ARM64 `virt`、Cortex-A53、1 个 vCPU、1 GiB RAM、TCG；Buildroot 2026.08.1（内部 glibc 交叉工具链）；Linux v6.18.60；U-Boot v2026.10。它是固定教学基线，不代表最新版本，也不适用于生产环境。请以实际构建和启动结果为准；新版本组合尚未完整编译、启动验收。

## 1. 先理解组成和启动路径

- **Buildroot** 生成 ARM64 用户空间 rootfs，并构建交叉编译器。工具链位于 `out/buildroot-2026.08.1/host/bin/`。
- **Linux** 使用 Buildroot 的交叉编译器构建内核 `Image`（启动用，无调试符号）和 `vmlinux`（含调试信息）。
- **U-Boot** 同样使用这个交叉编译器构建 `u-boot.bin`。
- **QEMU `virt`** 提供虚拟串口、virtio 块设备、virtio 网卡等设备。先用 QEMU 直接启动 Linux 验证内核和 rootfs，再用 U-Boot 启动同一内核与 rootfs。

启动链路是：QEMU → U-Boot → Linux Image → virtio 块设备上的 Buildroot rootfs。初学时先完成直接启动 Linux 的路径，再验证 U-Boot，出错时更容易定位问题。

## 2. 主机准备

### 2.1 安装依赖

打开终端执行：

```bash
sudo apt update
sudo apt install -y \
  bc bison build-essential ca-certificates cpio device-tree-compiler \
  file flex gdb-multiarch git libelf-dev libncurses-dev libssl-dev make \
  pkg-config python3 python3-venv rsync unzip wget xz-utils \
  curl \
  qemu-system-arm
```

Ubuntu 的 `qemu-system-arm` 包提供 `qemu-system-aarch64`。`device-tree-compiler` 提供 `dtc`。安装后确认：

```bash
qemu-system-aarch64 --version
git --version
dtc --version
gdb-multiarch --version
```

无需安装主机上的 aarch64 GCC：Buildroot 会构建本指南统一使用的工具链。建议至少预留 40 GiB 可用磁盘和 8 GiB 主机内存；保留多个版本时应预留更多空间，这不是严格最低要求。若主机内存紧张，可在后文将 `JOBS` 调小。本文不对构建耗时作保证。

源码和构建路径应避免空格。不要以 `sudo make` 构建，否则文件可能归 root 所有，后续普通用户无法更新。

### 2.2 可选：从源码构建固定版 QEMU 8.2.2

Ubuntu 仓库提供的 QEMU 已足够用于主线步骤。如果希望固定 QEMU 版本，可额外构建 8.2.2。user-mode networking 需要 `libslirp-dev`，并使用 `--enable-slirp` 显式启用；Ninja 用于构建：

```bash
sudo apt install -y libglib2.0-dev libpixman-1-dev libslirp-dev \
  ninja-build pkg-config zlib1g-dev
mkdir -p "$HOME/src" "$HOME/build"
cd "$HOME/src"
curl -fL https://download.qemu.org/qemu-8.2.2.tar.xz -o qemu-8.2.2.tar.xz
tar -xf qemu-8.2.2.tar.xz
mkdir -p "$HOME/build/qemu-8.2.2"
cd "$HOME/build/qemu-8.2.2"
"$HOME/src/qemu-8.2.2/configure" \
  --target-list=aarch64-softmmu --enable-slirp --ninja="$(command -v ninja)"
ninja
```

若 configure 报告 Python 模块 `meson` 缺失（例如离线主机未提供该模块），按 QEMU configure 的报错安装/提供它后重新运行 configure；不要在没有对应报错时额外猜测依赖。构建产物通常位于该构建目录的 `qemu-system-aarch64`。可用其绝对路径替代后文命令中的 `qemu-system-aarch64`，并用 `--version` 确认实际运行的版本。源码构建不是主线必需步骤。

## 3. 创建工作目录和环境文件

以下命令在你希望放置工程的目录执行。示例工程路径是 `$HOME/linux-qemu`，如果仓库已在别处，请先进入仓库根目录，而不是再创建另一份仓库。

```bash
cd "$HOME/linux-qemu"
mkdir -p src/buildroot src/linux src/u-boot \
  out configs scripts
```

在仓库根目录创建 `env.sh`。所有版本及路径集中在这里：切换版本时修改版本变量，再重新加载环境即可。

```bash
cat > env.sh <<'EOF'
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
EOF
```

每个新终端都要在仓库根目录加载一次：

```bash
cd "$HOME/linux-qemu"
. ./env.sh
printf 'root=%s\nBR=%s\nLinux=%s\nU-Boot=%s\n' \
  "$PROJECT_ROOT" "$BR_OUT" "$LINUX_OUT" "$UBOOT_OUT"
```

`env.sh` 不包含秘密，并通过自身路径动态定位工程根目录；它也是集中锁定版本的入口，建议提交到 Git。它不会将 Buildroot 的 `host/bin` 加入全局 `PATH`，避免其工具意外影响其他构建；内核和 U-Boot 均明确传入 `CROSS_COMPILE`。

建议在仓库根目录创建 `.gitignore`（请自行执行，本文不代替你写入仓库文件）：

```gitignore
/src/buildroot/
/src/linux/
/src/u-boot/
/out/
```

若要版本管理配置，可按需将 `configs/` 和运行脚本提交；不要提交完整 `out/`。建议单独备份环境变量文件，因为这里记录了当前版本选择。

## 4. 获取固定版本源码

Buildroot 的发布仓库标签为 `2026.08.1`；Linux stable 与 U-Boot 标签分别为 `v6.18.60`、`v2026.10`。这里使用浅克隆以减少下载量。若目录不是空目录，先检查内容，勿用命令覆盖你的本地工作。

```bash
. ./env.sh
git clone --depth 1 --branch "$BUILDROOT_VERSION" \
  https://gitlab.com/buildroot.org/buildroot.git "$BR_SRC"
git clone --depth 1 --branch "$LINUX_VERSION" \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$LINUX_SRC"
git clone --depth 1 --branch "$UBOOT_VERSION" \
  https://source.denx.de/u-boot/u-boot.git "$UBOOT_SRC"
```

记录标签和提交号，便于复现：

```bash
git -C "$BR_SRC" status --short --branch
git -C "$BR_SRC" rev-parse HEAD
git -C "$LINUX_SRC" status --short --branch
git -C "$LINUX_SRC" rev-parse HEAD
git -C "$UBOOT_SRC" status --short --branch
git -C "$UBOOT_SRC" rev-parse HEAD
```

Linux 使用 stable 树的维护版本，仓库为 `https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`。请记录仓库 URL 和 commit；不要把不同仓库的同名版本标签视作同一提交。

## 5. 配置并构建 Buildroot rootfs

先用一个明确、可保存的 defconfig。以下所需符号已针对 Buildroot 2026.08.1 固定标签核对：选择 ARM64 Cortex-A53、Buildroot 内建 glibc 工具链、ext4 rootfs、串口登录和 eth0 DHCP。请在生成配置后检查最终 `.config`；新基线尚未完整编译启动。Buildroot 默认不集成内核、bootloader 或 host QEMU；不要改用官方 `qemu_aarch64_virt_defconfig` 作起点，因为它会集成 kernel 和 host QEMU。root 登录无密码仅供隔离的本地教学虚拟机使用，绝不用于联网或生产系统。

```bash
cd "$PROJECT_ROOT"
cat > configs/buildroot_defconfig <<'EOF'
BR2_aarch64=y
BR2_cortex_a53=y
BR2_TOOLCHAIN_BUILDROOT=y
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_KERNEL_HEADERS_6_18=y
BR2_SYSTEM_DHCP="eth0"
BR2_TARGET_GENERIC_HOSTNAME="qemu-arm64"
BR2_TARGET_ENABLE_ROOT_LOGIN=y
BR2_TARGET_GENERIC_ROOT_PASSWD=""
BR2_TARGET_GENERIC_GETTY=y
BR2_TARGET_GENERIC_GETTY_PORT="ttyAMA0"
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_EXT2_SIZE="256M"
EOF
```

> Buildroot 配置符号会随版本变化。若 `defconfig` 报未知符号或生成配置与期望不符，以固定版本的 Kconfig 为准，检查 `make menuconfig` 与 `make savedefconfig` 的结果；不要忽略告警后假定配置生效。

`BR2_KERNEL_HEADERS_6_18=y` 选择 Buildroot 2026.08.1 提供的 Linux 6.18.55 headers。Buildroot 此版本默认 headers 已升至 7.1，因此必须显式选择 6.18；工具链 headers 与运行 Linux v6.18.60 同属 6.18 系列即可，不要求 patch 版本完全相同。不要随意搭配更旧内核或不兼容的用户空间 ABI。符号及版本可在[固定版本的 `package/linux-headers/Config.in.host`](https://raw.githubusercontent.com/buildroot/buildroot/2026.08.1/package/linux-headers/Config.in.host) 核对。

已在官方 Buildroot 2026.08.1 源码上，使用本文的精确 defconfig 实际运行 `make defconfig` 和 `make olddefconfig`：确认 ARM64 Cortex-A53、glibc、6.18.55 headers、`ttyAMA0`、256 MiB ext4，以及未集成 kernel/U-Boot/host QEMU。此检查只验证配置生成，不代表工具链、rootfs 或新版本组合已完整编译、启动验收；本地构建时仍需检查最终 `.config`。

生成 Buildroot 输出配置并编译：

```bash
. ./env.sh
make -C "$BR_SRC" O="$BR_OUT" \
  BR2_DEFCONFIG="$PROJECT_ROOT/configs/buildroot_defconfig" defconfig
make -C "$BR_SRC" O="$BR_OUT" olddefconfig
grep -E '^(BR2_aarch64|BR2_cortex_a53|BR2_TOOLCHAIN_BUILDROOT|BR2_TOOLCHAIN_BUILDROOT_GLIBC|BR2_KERNEL_HEADERS_6_18|BR2_TARGET_GENERIC_GETTY_PORT|BR2_TARGET_ROOTFS_EXT2_SIZE)=' \
  "$BR_OUT/.config"
if grep -Eq '^(BR2_LINUX_KERNEL|BR2_TARGET_UBOOT|BR2_PACKAGE_HOST_QEMU)=y$' "$BR_OUT/.config"; then
  printf 'Unexpected integrated kernel/U-Boot/host QEMU option in Buildroot config\n' >&2
  false
else
  make -C "$BR_SRC" O="$BR_OUT" -j"$JOBS"
fi
```

编译完成后检查工具链和 rootfs：

```bash
test -x "${CROSS_COMPILE}gcc"
"${CROSS_COMPILE}gcc" --version
"${CROSS_COMPILE}gcc" -dumpmachine
ls -lh "$BR_OUT/images"/rootfs.ext*
```

`-dumpmachine` 应输出 `aarch64-buildroot-linux-gnu`，与 `CROSS_COMPILE` 前缀一致。

Buildroot 的 ext4 配置项沿用 `EXT2` 命名空间；输出通常是 `rootfs.ext2`，有些版本/配置还会提供 `rootfs.ext4` 链接。后面的启动命令统一使用 `rootfs.ext4`，先检查并按实际产物建立链接：

```bash
if [[ ! -e "$BR_OUT/images/rootfs.ext4" && -e "$BR_OUT/images/rootfs.ext2" ]]; then
  ln -s rootfs.ext2 "$BR_OUT/images/rootfs.ext4"
fi
readlink -f "$BR_OUT/images/rootfs.ext4"
```

`readlink` 必须指向本次 Buildroot 的 ext 文件。rootfs 镜像应至少有 256 MiB；如需更大容量，调整 defconfig 的 `BR2_TARGET_ROOTFS_EXT2_SIZE` 后重新配置、构建。

后续用 `menuconfig` 调整 Buildroot 配置时，先加载当前输出配置再编辑；保存精简配置到仓库后再重建：

```bash
. ./env.sh
make -C "$BR_SRC" O="$BR_OUT" menuconfig
make -C "$BR_SRC" O="$BR_OUT" \
  BR2_DEFCONFIG="$PROJECT_ROOT/configs/buildroot_defconfig" savedefconfig
make -C "$BR_SRC" O="$BR_OUT" -j"$JOBS"
```

`savedefconfig` 会更新 `configs/buildroot_defconfig`，供后续复现使用。普通软件包启用/调整通常可在同一输出目录增量构建；不要重新对同一输出目录执行 `defconfig`，否则会以精简 defconfig 重置 `.config` 中未保存的设置。若变更架构、工具链、libc 或 ABI，按第 13 节使用全新 Buildroot 输出目录完整重建，不能假设旧工具链产物可安全增量更新。

## 6. 构建 U-Boot

U-Boot 的 `ARCH=arm` 构建目录同时覆盖 AArch32 与 AArch64 目标；本例的 `qemu_arm64_defconfig` 生成的是 64 位 ARM U-Boot，不代表存在 32 位启动阶段。交叉工具链目标仍是 aarch64：

```bash
. ./env.sh
make -C "$UBOOT_SRC" O="$UBOOT_OUT" \
  ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" qemu_arm64_defconfig
make -C "$UBOOT_SRC" O="$UBOOT_OUT" \
  ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"
```

保存精简的用户配置，以便版本迁移：

```bash
make -C "$UBOOT_SRC" O="$UBOOT_OUT" \
  ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" savedefconfig
cp "$UBOOT_OUT/defconfig" "$PROJECT_ROOT/configs/u-boot_defconfig"
ls -lh "$UBOOT_OUT/u-boot.bin" "$UBOOT_OUT/u-boot"
```

`u-boot.bin` 是启动用原始镜像，`u-boot` 是 ELF 符号文件。调试时不要把 `.bin` 当成带符号的 ELF。

## 7. 配置并构建 Linux

先由上游 ARM64 默认配置开始，再显式确保虚拟机启动和调试所需驱动内建（`=y`，不是模块）。不启用模块可避免当前教学流程还需安装匹配模块。配置文件位于独立的 `LINUX_OUT`，不会污染源码树。

```bash
. ./env.sh
make -C "$LINUX_SRC" O="$LINUX_OUT" \
  ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" defconfig

"$LINUX_SRC/scripts/config" --file "$LINUX_OUT/.config" \
  --enable CONFIG_VIRTIO \
  --enable CONFIG_VIRTIO_MMIO \
  --enable CONFIG_VIRTIO_BLK \
  --enable CONFIG_VIRTIO_NET \
  --enable CONFIG_EXT4_FS \
  --enable CONFIG_DEVTMPFS \
  --enable CONFIG_DEVTMPFS_MOUNT \
  --enable CONFIG_SERIAL_AMBA_PL011 \
  --enable CONFIG_SERIAL_AMBA_PL011_CONSOLE \
  --disable CONFIG_MODULES \
  --disable CONFIG_DEBUG_INFO_NONE \
  --enable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
  --disable CONFIG_DEBUG_INFO_REDUCED \
  --enable CONFIG_DEBUG_INFO_COMPRESSED_NONE \
  --disable CONFIG_DEBUG_INFO_COMPRESSED_ZLIB \
  --disable CONFIG_DEBUG_INFO_COMPRESSED_ZSTD \
  --enable CONFIG_GDB_SCRIPTS \
  --enable CONFIG_FRAME_POINTER

make -C "$LINUX_SRC" O="$LINUX_OUT" \
  ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
```

检查关键配置实际存在且为内建：

```bash
grep -E '^(CONFIG_(VIRTIO|VIRTIO_MMIO|VIRTIO_BLK|VIRTIO_NET|EXT4_FS|DEVTMPFS|DEVTMPFS_MOUNT|SERIAL_AMBA_PL011|SERIAL_AMBA_PL011_CONSOLE|DEBUG_INFO|GDB_SCRIPTS|FRAME_POINTER|DEBUG_INFO_COMPRESSED_NONE)=|# CONFIG_(MODULES|DEBUG_INFO_REDUCED|DEBUG_INFO_COMPRESSED_ZLIB|DEBUG_INFO_COMPRESSED_ZSTD) is not set)' \
  "$LINUX_OUT/.config"
grep -q '^CONFIG_VIRTIO_NET=y$' "$LINUX_OUT/.config"
grep -q '^CONFIG_DEBUG_INFO=y$' "$LINUX_OUT/.config"
grep -q '^CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y$' "$LINUX_OUT/.config"
grep -q '^# CONFIG_MODULES is not set$' "$LINUX_OUT/.config"
```

ARM64 `defconfig` 已默认启用本机所需的多项驱动；这里仍显式确保 virtio、virtio-mmio、virtio-blk、virtio-net、ext4、devtmpfs、PL011 串口等为 `y`。禁用 `MODULES` 后运行 `olddefconfig` 会清理配置中不再可用的 `m` 项，因此构建后要检查最终 `.config`，尤其确认 `CONFIG_VIRTIO_NET=y`。`DEBUG_INFO` 是 Kconfig 派生的隐藏项，不应直接把它当作可独立选择的选项：禁用 `DEBUG_INFO_NONE`、启用 `DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT`，并选择 `DEBUG_INFO_COMPRESSED_NONE`、禁用 ZLIB/ZSTD 压缩及 reduced 信息，再经 `olddefconfig` 核实 `CONFIG_DEBUG_INFO=y`。Linux 6.18 的压缩调试信息为 choice，以上配置明确选择不压缩。所有选项都应在最终 `.config` 中检查，不要忽略未知配置或 Kconfig 告警。`CONFIG_FRAME_POINTER` 若该架构配置适用则开启，否则以 Kconfig 最终结果为准。

编译启动镜像和调试文件：

```bash
make -C "$LINUX_SRC" O="$LINUX_OUT" \
  ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
  -j"$JOBS" Image vmlinux scripts_gdb
```

保存精简配置：

```bash
make -C "$LINUX_SRC" O="$LINUX_OUT" \
  ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" savedefconfig
cp "$LINUX_OUT/defconfig" "$PROJECT_ROOT/configs/linux_defconfig"
file "$LINUX_OUT/arch/arm64/boot/Image" "$LINUX_OUT/vmlinux"
```

`Image` 用于 QEMU 启动，不含可用于源代码级调试的完整符号；`vmlinux` 是 GDB 使用的带符号 ELF。`scripts_gdb` 目标生成/更新 `vmlinux-gdb.py` 等 GDB 辅助脚本。每次配置修改后都应重新检查 `.config`，必要时重新构建。

## 8. 直接启动 Linux：先验证 rootfs

在终端加载环境并启动：

```bash
. ./env.sh
qemu-system-aarch64 \
  -machine virt -cpu cortex-a53 -smp 1 -m 1G -accel tcg \
  -kernel "$LINUX_OUT/arch/arm64/boot/Image" \
  -append 'console=ttyAMA0 root=/dev/vda rw rootwait nokaslr' \
  -drive if=none,file="$BR_OUT/images/rootfs.ext4",format=raw,id=rootfs \
  -device virtio-blk-device,drive=rootfs \
  -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
  -nographic -snapshot
```

预期在串口看到 Linux 启动、挂载根文件系统和登录提示。登录用户为 `root`，在本地隔离的教学 VM 中无需密码。网络设备使用 QEMU user-mode networking 和 DHCP，但主线不要求联网或 SSH，也没有把服务暴露到宿主机。按 **Ctrl-a** 后按 **x** 退出；按 **Ctrl-a** 后按 **c** 切换 QEMU monitor。

`-snapshot` 使本次运行的写入不落入 rootfs 原镜像，适合反复试验。要持久保存来宾写入，移除 `-snapshot`；退出后原镜像会被修改。不要让多个 QEMU 进程同时以可写方式打开同一 rootfs。重新构建 Buildroot 可能覆盖镜像，若已保存来宾数据，先停机并备份该镜像，或用独立副本作为日常运行盘。

## 9. 使用 U-Boot 启动 Linux

QEMU `virt` 机器的设备树应与实际启动时拓扑一致。先使用与正式启动相同的 CPU、内存和设备参数生成 DTB；`dumpdtb` 阶段不要加 GDB 的 `-S`/`-gdb` 参数。QEMU 会生成 DTB 并退出：

```bash
. ./env.sh
qemu-system-aarch64 \
  -machine virt,dumpdtb="$RUN_DIR/virt.dtb" \
  -cpu cortex-a53 -smp 1 -m 1G -accel tcg \
  -bios "$UBOOT_OUT/u-boot.bin" \
  -drive if=none,file="$BR_OUT/images/rootfs.ext4",format=raw,id=rootfs \
  -device virtio-blk-device,drive=rootfs \
  -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
  -nographic
test -s "$RUN_DIR/virt.dtb"
dtc -I dtb -O dts "$RUN_DIR/virt.dtb" -o "$RUN_DIR/virt.dts"
```

QEMU virt 的 RAM 范围是 `[0x40000000, 0x80000000)`。U-Boot v2026.10 的 `qemu_arm64_defconfig` 初始化栈和默认 load 地址在 `0x40200000`，因此**不能**把内核 loader 放到该地址。统一将 Linux Image 放在 `0x48000000`，DTB 放在 `0x4f000000`；确保 Image 小于 112 MiB，避免与 DTB 地址重叠。U-Boot 会自行搬迁；不要硬编码 `fdtcontroladdr` 来替代传给 `booti` 的来宾 DTB。

启动时把 Linux Image 和刚才生成的 DTB 装入指定地址：

```bash
. ./env.sh
qemu-system-aarch64 \
  -machine virt -cpu cortex-a53 -smp 1 -m 1G -accel tcg \
  -bios "$UBOOT_OUT/u-boot.bin" \
  -device loader,file="$LINUX_OUT/arch/arm64/boot/Image",addr=0x48000000,force-raw=on \
  -device loader,file="$RUN_DIR/virt.dtb",addr=0x4f000000,force-raw=on \
  -drive if=none,file="$BR_OUT/images/rootfs.ext4",format=raw,id=rootfs \
  -device virtio-blk-device,drive=rootfs \
  -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
  -nographic -snapshot
```

在 U-Boot 提示符输入：

```text
setenv bootargs 'console=ttyAMA0 root=/dev/vda rw rootwait nokaslr'
booti 0x48000000 - 0x4f000000
```

`booti` 参数依次是未压缩 ARM64 `Image` 地址、可选 initrd（此处无，写 `-`）、设备树地址。`-device loader` 仅加载文件；不要给这些 loader 设备添加 `cpu-num`，因为那会设置 CPU 程序计数器，可能直接跳过 U-Boot。DTB 必须在 QEMU 设备拓扑变化后重新生成。dumpdtb 与正式启动均使用相同的 `-bios u-boot.bin` 和设备参数；虽然 QEMU 官方说明 firmware 树与 dumpdtb 的生成不必相同，本指南为减少变量仍保持一致。此前使用 QEMU 8.2.2 通过 QMP 验证了相同 CPU/RAM/virtio 网络与块设备参数下的 `dumpdtb`（含 `-bios`）、RAM/PL011 设备树信息、loader 地址组合及 GDB 绑定参数可启动并退出；**这只是 QEMU 参数级检查，不是本次 Buildroot/Linux/U-Boot 新版本的端到端启动验证**。使用与直接启动相同的 rootfs 和控制台参数，便于比较问题是在 U-Boot 前还是 Linux/rootfs 阶段出现。

## 10. 日常启动脚本（可选）

确认手动启动后，可在本地创建脚本统一参数。下方 heredoc 只是供你执行的命令；脚本不由本文自动写入仓库。

```bash
. ./env.sh
cat > scripts/run-qemu.sh <<'EOF'
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
    -nographic
  test -s "$RUN_DIR/virt.dtb"
  qemu+=(-bios "$UBOOT_OUT/u-boot.bin"
    -device "loader,file=$LINUX_OUT/arch/arm64/boot/Image,addr=0x48000000,force-raw=on"
    -device "loader,file=$RUN_DIR/virt.dtb,addr=0x4f000000,force-raw=on")
fi

if [[ "${DEBUG:-0}" == 1 ]]; then
  qemu+=(-S -gdb tcp:127.0.0.1:1234)
fi
exec "${qemu[@]}"
EOF
chmod +x scripts/run-qemu.sh
```

用法：

```bash
./scripts/run-qemu.sh linux
./scripts/run-qemu.sh uboot
DEBUG=1 ./scripts/run-qemu.sh linux
DEBUG=1 ./scripts/run-qemu.sh uboot
```

`DEBUG=1` 只暂停正式 VM 并监听本机回环地址的 GDB 端口。调试时不要同时启动多个占用 `1234` 端口的实例。

## 11. GDB 调试

先在终端 A 运行 `DEBUG=1 ./scripts/run-qemu.sh linux`。QEMU 暂停在启动 CPU；另开终端 B：

```bash
. ./env.sh
gdb-multiarch "$LINUX_OUT/vmlinux"
```

在 GDB 中执行：

```gdb
set architecture aarch64
target remote :1234
hbreak start_kernel
continue
```

`nokaslr` 使内核地址稳定。这里用硬件断点，避免 Linux 早期初始化阶段软件断点改写内存导致的问题。内核在 U-Boot 启动链中还可能有早期映射/地址转换因素；**直接 Linux 启动是本指南推荐且较可靠的内核源码级调试路径**。GDB 可在适当时使用 `bt`、`info registers`、`list`、`p` 等命令。

调试 U-Boot 时启动 `DEBUG=1 ./scripts/run-qemu.sh uboot`，然后 GDB 加载 ELF：

```bash
. ./env.sh
gdb-multiarch "$UBOOT_OUT/u-boot"
```

```gdb
set architecture aarch64
target remote :1234
hbreak _start
continue
```

`_start` 断点命中后执行 `continue`，让 U-Boot 继续运行到串口提示符。在 QEMU 串口终端输入 `bdinfo`，记录 `relocaddr` 和 `reloc off`；不要先在 GDB Ctrl-C 暂停 guest，否则串口命令无法执行。记录完成后再切到 GDB 终端按 Ctrl-C 暂停目标，用 `help add-symbol-file` 核对当前 GDB 版本的语法，然后清除旧符号并添加重定位后的 ELF 符号：

```gdb
symbol-file
add-symbol-file /绝对路径/linux-qemu/out/u-boot-v2026.10/u-boot -o 0x实际reloc-off
```

将绝对路径和偏移替换成实际值；`0x实际reloc-off` 是占位说明，不可原样输入。GDB 交互命令不会展开 shell 中的 `$UBOOT_OUT`，这里必须使用实际路径。偏移方式通常比仅指定 `.text` 地址更稳妥，但应依该版本 GDB 的帮助和 U-Boot 符号布局验证。不要使用 `u-boot.bin` 作为符号文件，也不要让 GDB 执行 `load` 覆盖 QEMU 已加载的镜像。

若 GDB 报 Python 脚本安全路径警告，只对可信的内核源码目录添加 safe-path，不要放开所有路径：

启动 GDB 时需在加载 `vmlinux` 前设置 safe-path，才能让自动脚本在加载 ELF 时生效，例如：

```bash
gdb-multiarch -iex 'add-auto-load-safe-path /绝对路径/linux-qemu/src/linux' \
  /绝对路径/linux-qemu/out/linux-v6.18.60/vmlinux
```

不要使用 `*` 放开全部路径。若当前 GDB 已加载 ELF，先退出并按上述方式重新启动。

内核诊断可在启动参数中临时增加 `ignore_loglevel`，或用 `dmesg` 检查环形缓冲区。需要 QEMU 额外日志时，可在正式 QEMU 参数加 `-D "$RUN_DIR/qemu.log" -d guest_errors,unimp`。不要默认使用 `in_asm`，它可能产生非常大的日志文件。

## 12. 独立更新 Linux 或 U-Boot（重要）

版本变量、源码目录与按版本命名的输出目录已分离。一次只更新 Linux 或 U-Boot 中的一个，旧输出保留，便于 A/B 比较和回退。开始前分别检查仓库状态：

```bash
. ./env.sh
git -C "$LINUX_SRC" status --short --branch
git -C "$UBOOT_SRC" status --short --branch
```

本地修改（包括 staged、unstaged 和 untracked 文件）先自行审阅并 commit 或备份；`git diff` 只包含 unstaged tracked 修改，不包含 staged 或 untracked 内容，不能作为完整备份。不要以 `git reset --hard`、`git clean` 丢弃本地文件。

### 12.1 Linux：升级到一个已发布的新 tag

先保存当前版本、旧输出目录及完整配置。输入一个你已确认要升级到的已发布 Linux stable tag；输入为空或与当前 tag 相同会拒绝，远端不存在的 tag 不会进入 fetch/checkout：

```bash
. ./env.sh
OLD_LINUX_VERSION="$LINUX_VERSION"
OLD_LINUX_OUT="$LINUX_OUT"
cp "$OLD_LINUX_OUT/.config" "$RUN_DIR/linux-${OLD_LINUX_VERSION}-full.config"
read -r -p '已发布的 Linux stable tag（例如 v6.x.y）: ' NEW_LINUX_VERSION
if [[ -z "$NEW_LINUX_VERSION" || "$NEW_LINUX_VERSION" == "$OLD_LINUX_VERSION" ]]; then
  printf 'tag 为空或与当前版本相同，停止升级。\n' >&2
elif git -C "$LINUX_SRC" ls-remote --exit-code --tags origin "refs/tags/$NEW_LINUX_VERSION" >/dev/null; then
  git -C "$LINUX_SRC" fetch --depth=1 origin tag "$NEW_LINUX_VERSION" &&
    git -C "$LINUX_SRC" switch --detach "$NEW_LINUX_VERSION" &&
    git -C "$LINUX_SRC" rev-parse HEAD
else
  printf '远端不存在该 Linux tag，未执行 fetch/checkout。\n' >&2
fi
```

只有确认 tag 检查、fetch 和 checkout 成功后才继续。编辑 `env.sh`，将 `LINUX_VERSION` 改成同一个 `$NEW_LINUX_VERSION` 的实际值，然后在当前终端重新加载：

```bash
. ./env.sh
printf 'old=%s\nnew=%s\n' "$OLD_LINUX_OUT" "$LINUX_OUT"
test "$LINUX_OUT" != "$OLD_LINUX_OUT"
```

新输出目录按 `out/linux-$NEW_LINUX_VERSION` 命名。复制旧完整配置，先查看新版本配置项，再迁移并审核差异：

```bash
mkdir -p "$LINUX_OUT"
cp "$OLD_LINUX_OUT/.config" "$LINUX_OUT/.config"
make -C "$LINUX_SRC" O="$LINUX_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" listnewconfig
make -C "$LINUX_SRC" O="$LINUX_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
"$LINUX_SRC/scripts/diffconfig" "$OLD_LINUX_OUT/.config" "$LINUX_OUT/.config"
grep -E 'CONFIG_(VIRTIO|VIRTIO_MMIO|VIRTIO_BLK|VIRTIO_NET|EXT4_FS|DEVTMPFS|DEVTMPFS_MOUNT|SERIAL_AMBA_PL011|SERIAL_AMBA_PL011_CONSOLE|DEBUG_INFO|GDB_SCRIPTS)=' "$LINUX_OUT/.config"
```

逐项审核所需内建配置；配置丢失时按第 7 节补回并复核。完整 `.config` 备份与精简 `configs/linux_defconfig` 用途不同。构建新版本并保存精简配置：

```bash
make -C "$LINUX_SRC" O="$LINUX_OUT" \
  ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
  -j"$JOBS" Image vmlinux scripts_gdb
make -C "$LINUX_SRC" O="$LINUX_OUT" \
  ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" savedefconfig
cp "$LINUX_OUT/defconfig" "$PROJECT_ROOT/configs/linux_defconfig"
```

运行脚本每次读取 `env.sh` 的 `LINUX_OUT`，无需改脚本。启动后用 `uname -r` 确认内核版本；旧版本输出仍保留，不覆盖旧目录。

### 12.2 U-Boot：升级到一个已发布的新 tag

先保存当前版本、旧输出目录及完整配置。输入一个已发布的 U-Boot tag；输入为空/当前版本，或远端不存在的 tag 时，不会继续 fetch/checkout：

```bash
. ./env.sh
OLD_UBOOT_VERSION="$UBOOT_VERSION"
OLD_UBOOT_OUT="$UBOOT_OUT"
cp "$OLD_UBOOT_OUT/.config" "$RUN_DIR/u-boot-${OLD_UBOOT_VERSION}-full.config"
read -r -p '已发布的 U-Boot tag（例如 v202x.y）: ' NEW_UBOOT_VERSION
if [[ -z "$NEW_UBOOT_VERSION" || "$NEW_UBOOT_VERSION" == "$OLD_UBOOT_VERSION" ]]; then
  printf 'tag 为空或与当前版本相同，停止升级。\n' >&2
elif git -C "$UBOOT_SRC" ls-remote --exit-code --tags origin "refs/tags/$NEW_UBOOT_VERSION" >/dev/null; then
  git -C "$UBOOT_SRC" fetch --depth=1 origin tag "$NEW_UBOOT_VERSION" &&
    git -C "$UBOOT_SRC" switch --detach "$NEW_UBOOT_VERSION" &&
    git -C "$UBOOT_SRC" rev-parse HEAD
else
  printf '远端不存在该 U-Boot tag，未执行 fetch/checkout。\n' >&2
fi
```

仅在 tag 检查、fetch、checkout 都成功后继续。编辑 `env.sh`，将 `UBOOT_VERSION` 改成同一个 `$NEW_UBOOT_VERSION` 的实际值，重新加载并确认新输出路径：

```bash
. ./env.sh
printf 'old=%s\nnew=%s\n' "$OLD_UBOOT_OUT" "$UBOOT_OUT"
test "$UBOOT_OUT" != "$OLD_UBOOT_OUT"
```

在 `out/u-boot-$NEW_UBOOT_VERSION` 新目录迁移配置：

```bash
mkdir -p "$UBOOT_OUT"
cp "$OLD_UBOOT_OUT/.config" "$UBOOT_OUT/.config"
make -C "$UBOOT_SRC" O="$UBOOT_OUT" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" listnewconfig
make -C "$UBOOT_SRC" O="$UBOOT_OUT" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
```

审核新配置差异并构建，保存新的精简配置：

```bash
"$UBOOT_SRC/scripts/diffconfig" \
  "$OLD_UBOOT_OUT/.config" "$UBOOT_OUT/.config"
make -C "$UBOOT_SRC" O="$UBOOT_OUT" \
  ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"
make -C "$UBOOT_SRC" O="$UBOOT_OUT" \
  ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" savedefconfig
cp "$UBOOT_OUT/defconfig" "$PROJECT_ROOT/configs/u-boot_defconfig"
```

使用当前脚本启动新 U-Boot，在串口执行 `version`、`bdinfo`，确认版本、RAM 与重定位信息符合预期。旧版本输出不覆盖。

### 12.3 使用保存的精简配置初始化新输出目录

首次构建可分别使用本指南中的 `defconfig`。若要以仓库保存的精简配置初始化一个新的输出目录，使用 `mkdir -p`、复制到 `.config` 后运行 `olddefconfig`；不要反复对已有目录执行 `defconfig` 覆盖配置：

```bash
. ./env.sh
mkdir -p "$LINUX_OUT"
cp "$PROJECT_ROOT/configs/linux_defconfig" "$LINUX_OUT/.config"
make -C "$LINUX_SRC" O="$LINUX_OUT" \
  ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

mkdir -p "$UBOOT_OUT"
cp "$PROJECT_ROOT/configs/u-boot_defconfig" "$UBOOT_OUT/.config"
make -C "$UBOOT_SRC" O="$UBOOT_OUT" \
  ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
```

### 12.4 回退、同版本增量构建与调试配置重建

回退必须同时恢复 `env.sh` 版本、源码 checkout 和输出目录选择；不要只改其中一项。以下回到本指南基线 Linux v6.18.60（stable 仓库）：

```bash
git -C "$LINUX_SRC" fetch --depth=1 origin tag v6.18.60
git -C "$LINUX_SRC" switch --detach v6.18.60
# 编辑 env.sh：LINUX_VERSION="v6.18.60"
. ./env.sh
printf 'Linux=%s source=%s\n' "$LINUX_OUT" "$(git -C "$LINUX_SRC" describe --tags --always)"
./scripts/run-qemu.sh linux
```

回退 U-Boot 到 v2026.10：

```bash
git -C "$UBOOT_SRC" fetch --depth=1 origin tag v2026.10
git -C "$UBOOT_SRC" switch --detach v2026.10
# 编辑 env.sh：UBOOT_VERSION="v2026.10"
. ./env.sh
printf 'U-Boot=%s source=%s\n' "$UBOOT_OUT" "$(git -C "$UBOOT_SRC" describe --tags --always)"
./scripts/run-qemu.sh uboot
```

原有 `out/linux-v6.18.60`、`out/u-boot-v2026.10` 均保留，不覆盖。如果此前已有该版本完整输出配置，继续使用该输出；若目录不存在或需重新生成，按 12.3 从保存的 defconfig 新建。启动 Linux 后用 `uname -r` 验证；U-Boot 串口用 `version`、`bdinfo` 验证。由早期版本指南迁移的用户不要原地覆盖旧输出；应以新基线的三个版本分别创建全新输出目录并完整构建。

同一 tag 下修改源码可在对应输出目录增量编译，例如：

```bash
make -C "$LINUX_SRC" O="$LINUX_OUT" \
  ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image vmlinux scripts_gdb
make -C "$UBOOT_SRC" O="$UBOOT_OUT" \
  ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"
```

仅修改内核调试配置、没有跨 tag 时，也在同一个 `LINUX_OUT` 修改 `.config` 后运行 `olddefconfig`，核验关键配置，再重建 `Image vmlinux scripts_gdb`；无需新版本目录，但要备份修改前的完整 `.config`，并视配置更新 `configs/linux_defconfig`。

## 13. Buildroot 更新和模块说明

Linux/U-Boot 单独更新时，通常可继续使用现有 Buildroot 工具链和 rootfs。Buildroot 更新必须同时更新源码 checkout 与 `env.sh` 版本；**只改 `BUILDROOT_VERSION` 不会切换 `src/buildroot` 的源码版本**。以下由用户输入一个已发布的新 tag，保留原输出目录/工具链，并在新输出目录完整构建：

```bash
. ./env.sh
OLD_BUILDROOT_VERSION="$BUILDROOT_VERSION"
OLD_BR_OUT="$BR_OUT"
git -C "$BR_SRC" status --short --branch
cp "$OLD_BR_OUT/.config" "$RUN_DIR/buildroot-${OLD_BUILDROOT_VERSION}-full.config"
read -r -p '已发布的 Buildroot tag: ' NEW_BUILDROOT_VERSION
if [[ -z "$NEW_BUILDROOT_VERSION" || "$NEW_BUILDROOT_VERSION" == "$OLD_BUILDROOT_VERSION" ]]; then
  printf 'tag 为空或与当前版本相同，停止升级。\n' >&2
elif git -C "$BR_SRC" ls-remote --exit-code --tags origin "refs/tags/$NEW_BUILDROOT_VERSION" >/dev/null; then
  git -C "$BR_SRC" fetch --depth=1 origin tag "$NEW_BUILDROOT_VERSION" &&
    git -C "$BR_SRC" switch --detach "$NEW_BUILDROOT_VERSION" &&
    git -C "$BR_SRC" rev-parse HEAD
else
  printf '远端不存在该 Buildroot tag，未执行 fetch/checkout。\n' >&2
fi
```

先检查并提交或备份本地修改，包括 staged、unstaged 和 untracked 内容；不要依赖 `git diff` 作为完整备份。只有 tag 检查、fetch、checkout 均成功后才继续。编辑 `env.sh`，将 `BUILDROOT_VERSION` 改为同一个 `$NEW_BUILDROOT_VERSION` 的实际值，保存后重新加载并确认新旧输出路径不同：

```bash
. ./env.sh
printf 'old=%s\nnew=%s\n' "$OLD_BR_OUT" "$BR_OUT"
test "$BR_OUT" != "$OLD_BR_OUT"
make -C "$BR_SRC" O="$BR_OUT" \
  BR2_DEFCONFIG="$PROJECT_ROOT/configs/buildroot_defconfig" defconfig
make -C "$BR_SRC" O="$BR_OUT" olddefconfig
grep -E '^(BR2_aarch64|BR2_cortex_a53|BR2_TOOLCHAIN_BUILDROOT|BR2_TOOLCHAIN_BUILDROOT_GLIBC|BR2_KERNEL_HEADERS_6_18|BR2_TARGET_GENERIC_GETTY_PORT|BR2_TARGET_ROOTFS_EXT2_SIZE)=' \
  "$BR_OUT/.config"
if grep -Eq '^(BR2_LINUX_KERNEL|BR2_TARGET_UBOOT|BR2_PACKAGE_HOST_QEMU)=y$' "$BR_OUT/.config"; then
  printf 'Unexpected integrated kernel/U-Boot/host QEMU option in Buildroot config\n' >&2
  false
else
  make -C "$BR_SRC" O="$BR_OUT" -j"$JOBS"
fi
```

审核输出配置、工具链目标和 rootfs 后再切换使用。旧 `$OLD_BR_OUT` 保留，作为旧工具链和 rootfs 回退点。

若 Buildroot tag 不变但更改了架构、工具链、libc 或 ABI 选项，也应让 `BR_OUT` 使用新的独立后缀并完整重建。更换了 Buildroot 工具链但 Linux/U-Boot 版本号不变时，它们按版本命名的输出目录不会自动变化：编辑 `env.sh`，把 `LINUX_OUT`、`UBOOT_OUT` 改为独立新路径（例如 `out/linux-$LINUX_VERSION-br${BUILDROOT_VERSION}`、`out/u-boot-$UBOOT_VERSION-br${BUILDROOT_VERSION}`），从保存的 `linux_defconfig`、`u-boot_defconfig` 初始化新 `.config`，执行 `olddefconfig` 并完整构建；不要在旧输出目录直接裸 `make`，复用的旧对象可能仍由原工具链生成。也可用 `-toolchain2` 等明确配置标记作为后缀。

再次确认工具链目标：

```bash
. ./env.sh
test -x "${CROSS_COMPILE}gcc"
"${CROSS_COMPILE}gcc" -dumpmachine
```

工具链目标应是 aarch64。更新后重新构建 Linux/U-Boot，并对新 rootfs 做启动验证。普通同版本源码修改可在对应输出目录增量 `make`；工具链或 Buildroot 配置变化则优先全新输出目录。

本指南默认禁用内核模块。若自行开启 `CONFIG_MODULES`，必须让内核与 rootfs 中的模块严格匹配；需执行类似 `make modules_install INSTALL_MOD_PATH="$BR_OUT/target"`，随后重建 Buildroot rootfs。直接修改 `target/` 不是持久方案：Buildroot 重建可能覆盖这些改动。长期维护应使用 Buildroot post-build hook，并把 hook 纳入版本管理。旧内核配新用户空间通常可工作，但模块、驱动及 ABI 仍需验证。

## 14. 复现记录建议

每次确认可启动的组合至少记录：三个源码仓库 URL、tag 与 `git rev-parse HEAD`，QEMU 版本，Buildroot 工具链 `gcc --version`/`-dumpmachine`，完整 Linux/U-Boot/Buildroot `.config`，rootfs 文件名和大小，以及启动参数。完整配置保存在版本化输出目录或单独归档，不必将整个 `out/` 提交到 Git。

## 15. 常见问题

| 现象 | 检查与处理 |
|---|---|
| `Kernel panic - not syncing: VFS: Unable to mount root fs` | 核对 `root=/dev/vda`、virtio-blk 驱动内建（`=y`）、rootfs 路径/格式和 `rootwait`。本配置整盘 ext4，设备是 `/dev/vda`，不是分区 `/dev/vda1`。 |
| `No working init found`、`cannot execute init` | 检查 rootfs 是否为 ARM64、rootfs 是否正确挂载、Buildroot 工具链 ABI 与内核架构是否匹配；确认使用刚构建的 rootfs。 |
| 串口没有输出 | 确认 `-nographic`、内核参数 `console=ttyAMA0`、内核 PL011 console 配置；在 U-Boot 中检查 `bootargs` 是否设置并传入 `booti`。 |
| `Bad Linux ARM64 Image magic` 或无法启动 | 确认使用未压缩 `arch/arm64/boot/Image`，而不是 `vmlinux`、`Image.gz` 或错误架构的镜像；核对加载地址 `0x48000000` 与 `booti` 地址一致。 |
| U-Boot 启动后找不到设备树/设备 | 使用与正式启动完全相同的 QEMU 拓扑重新生成 `out/run/virt.dtb`；核对 DTB 地址 `0x4f000000`、`booti` 第三个参数。 |
| rootfs 文件系统空间不足 | 增大 `BR2_TARGET_ROOTFS_EXT2_SIZE`，重新生成配置并构建 Buildroot；确认实际挂载的是新镜像。 |
| `aarch64-buildroot-linux-gnu-gcc: not found` | 先完成 Buildroot 构建；检查 `. ./env.sh`、`BR_OUT` 和 `${CROSS_COMPILE}gcc`。不要靠系统 PATH 中其他交叉编译器替代。 |
| 构建提示缺少 host 依赖 | 按报错安装对应 Ubuntu `-dev`/构建包，再重试；确保安装了本指南依赖（含 `flex`、`bison`、`libssl-dev`、`libncurses-dev`、`bc`、`device-tree-compiler`）。 |
| U-Boot `saveenv` 后重启设置消失 | QEMU 本例未配置持久化 pflash 环境存储；命令行中的 `setenv bootargs` 仅用于当前会话。 |
| GDB 断点地址不符/无法命中 | 内核使用 `nokaslr`；确认加载正确的 `vmlinux`。U-Boot 重定位后需重新核实运行地址及符号偏移；完整 U-Boot→内核链早期断点可能受 MMU/映射影响。 |
| WSL2 下提示 KVM 不可用 | 本方案明确使用 `-accel tcg`，不依赖 `/dev/kvm`；检查 QEMU 安装和 CPU 架构即可。 |
| 主机内存紧张 | 在当前 shell 执行 `JOBS=2; . ./env.sh`，或设置 `JOBS=2` 后再加载；关闭其他占用内存程序。 |

## 16. 官方资料

- [Buildroot 手册](https://buildroot.org/downloads/manual/manual.html)；[Buildroot 发布下载](https://buildroot.org/download.html)
- [Linux 内核文档](https://docs.kernel.org/)；[Linux stable 树](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git)
- [U-Boot v2026.10 文档](https://docs.u-boot.org/en/v2026.10/)
- [QEMU 8.2.2 文档](https://qemu.readthedocs.io/en/v8.2.2/)
- [QEMU ARM system emulator 文档](https://www.qemu.org/docs/master/system/target-arm.html)
- [QEMU invocation 手册](https://www.qemu.org/docs/master/system/invocation.html)
