# QEMU ARM64 构建排查记录

## 第 5 章：Buildroot 2026.08.1

状态：工具链和 rootfs 构建完成；尚未验证启动。仓库路径 `/home/terry/100_learning/linux-qemu`；Buildroot 提交 `7fdeadb3b9f12f78e5fccca914d7fef47090ab9a`。输出目录 `out/buildroot-2026.08.1`，执行时 `JOBS=2`，不使用 sudo。

按指南创建 `env.sh` 和 `configs/buildroot_defconfig`，先确认输出目录不存在，再运行 `make -C "$BR_SRC" O="$BR_OUT" BR2_DEFCONFIG="$PROJECT_ROOT/configs/buildroot_defconfig" defconfig`、同路径 `olddefconfig`，检查最终配置与未集成 kernel/U-Boot/host QEMU，再执行 `make -C "$BR_SRC" O="$BR_OUT" -j"$JOBS"`。

### 实际问题与处理

1. 默认 wget 下载 libtool 时代理连接成功但 TLS 返回 `unexpected eof while reading`，Buildroot 两个有效源均失败，第三个回退地址返回 404。用 `curl -IL https://sources.buildroot.net/libtool/libtool-2.5.4.tar.xz` 验证可经代理访问官方源。
2. 首次尝试 `BR2_WGET='curl -fL --retry 3 -o'` 失败：Buildroot 还传入 wget 的 `-O`，导致输出文件未创建、hash 检查失败；直接透传 `-O` 的包装脚本同样失败，因为 curl 的 `-O` 含义不同。并非实际确认源文件 hash 不匹配。
3. 在 `/tmp/opencode/buildroot-curl-wget` 创建临时适配器：检查第一个参数为 `-O`，将其后的输出路径转换为 `curl -fL --retry 3 -o "$output" "$@"`，然后以 `make -C "$BR_SRC" O="$BR_OUT" -j"$JOBS" BR2_WGET='/tmp/opencode/buildroot-curl-wget'` 增量续建；Buildroot 原有 hash 校验保留。构建日志在 `/tmp/opencode/buildroot-chapter5*.log`。
4. 一次前台执行在 1200 秒命令超时后被中断，GCC 构建显示 `Terminated`；保留输出并以无超时命令续建。之后 linux headers 和 busybox 下载分别遇到代理 TLS `SSL_ERROR_SYSCALL`，对官方镜像进行 HEAD 检查后分别重试同一增量命令，最终成功；没有清理输出目录。

### 验收

- 完整 `.config` 保留于输出目录：aarch64、Cortex-A53、内部 glibc、6.18.55 headers、`ttyAMA0`、`eth0` DHCP、ext4 256M；未启用集成 Linux、U-Boot、host QEMU。
- GCC 15.3.0；`"${CROSS_COMPILE}gcc" -dumpmachine` 输出 `aarch64-buildroot-linux-gnu`。
- `images/rootfs.ext2` 为 256 MiB；Buildroot 已生成 `rootfs.ext4 -> rootfs.ext2`，`readlink -f` 指向本次输出目录中的镜像。
- rootfs 的 QEMU 启动、内核、U-Boot 和后续章节尚未验证。

### 恢复检查

检查已有源码标签、配置、构建日志与产物后，以 `JOBS=2; . ./env.sh; make -C "$BR_SRC" O="$BR_OUT" -j"$JOBS" BR2_WGET='/tmp/opencode/buildroot-curl-wget'` 再次增量构建，成功退出；追加日志位于 `out/buildroot-build.log`。本次未发生新的下载错误。重新逐项断言上述配置、禁用集成选项和工具链三元组；使用 `stat -L` 验证镜像为 268435456 字节，并用 `file -L` 确认 ext4。重新构建可能重生成 rootfs 镜像，启动仍未验证。

## 第 6 章：U-Boot v2026.10

源码提交 `5508406582f6f7120dce0c4b3059819a41788db2`，源码工作树干净；输出目录 `out/u-boot-v2026.10` 起初不存在。执行 `. ./env.sh`，然后 `make -C "$UBOOT_SRC" O="$UBOOT_OUT" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" qemu_arm64_defconfig`，再用相同参数加 `-j2` 构建，不使用 sudo。

### 实际问题与处理

默认配置启用 `CONFIG_TOOLS_MKEFICAPSULE=y`，宿主机缺少开发头文件，编译报 `fatal error: gnutls/gnutls.h: No such file or directory`。中断恢复后未覆盖 `.config`，直接用同一 `make ... -j2` 增量重试，错误依旧。宿主已有运行时 `libgnutls.so.30`，但缺开发包。为保留默认配置且不修改系统，执行以下命令在临时目录下载并解包 Ubuntu 的开发包：

```bash
mkdir -p /tmp/opencode/uboot-host-deps
cd /tmp/opencode/uboot-host-deps
apt download libgnutls28-dev
dpkg-deb -x libgnutls28-dev*.deb root
```

首次只传 `HOSTCFLAGS=-I.../root/usr/include` 和 `HOSTLDFLAGS=-L.../root/usr/lib/x86_64-linux-gnu` 时，开发包的 `libgnutls.so` 链接目标缺失，链接器退而选择静态库，出现大量 `undefined reference`（如 `nettle_*`）。此机运行时库为 `/lib/x86_64-linux-gnu/libgnutls.so.30`；补充临时软链接后，增量构建成功：

```bash
ln -s /lib/x86_64-linux-gnu/libgnutls.so.30 /tmp/opencode/uboot-host-deps/root/usr/lib/x86_64-linux-gnu/libgnutls.so.30.37.1
. ./env.sh
make -C "$UBOOT_SRC" O="$UBOOT_OUT" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
  HOSTCFLAGS='-I/tmp/opencode/uboot-host-deps/root/usr/include' \
  HOSTLDFLAGS='-L/tmp/opencode/uboot-host-deps/root/usr/lib/x86_64-linux-gnu' -j2
```

以上路径和库版本是本机临时解决方案；其他系统应根据实际安装的开发包及运行时库调整。临时目录不是持久依赖，今后重建宿主工具需重新提供开发文件。

### 验收

- `make -C "$UBOOT_SRC" O="$UBOOT_OUT" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" savedefconfig` 成功，复制到 `configs/u-boot_defconfig` 并用 `cmp` 确认一致；完整配置为 `CONFIG_ARM64=y`、`CONFIG_TARGET_QEMU_ARM_64BIT=y`、`CONFIG_TOOLS_MKEFICAPSULE=y`。
- 交叉 GCC 15.3.0，`-dumpmachine` 为 `aarch64-buildroot-linux-gnu`。`file` 和交叉 `readelf -h` 确认 `u-boot` 是 ELF64 AArch64；`readelf -S` 确认 `.debug_info` 和 `.symtab`，且 `file` 显示未 strip。`readelf -S` 同时提示 section 6 的 link 字段警告，未影响上述检查。
- `test -s "$UBOOT_OUT/u-boot.bin"` 通过，大小 1501904 字节；ELF 为 10846952 字节。`file` 将原始 bin 误识别为 PCX，不能据此判断其格式。
- 尚未验证 U-Boot 在 QEMU 启动或与 Linux/rootfs 联合启动。
