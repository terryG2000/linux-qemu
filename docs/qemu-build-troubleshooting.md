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
