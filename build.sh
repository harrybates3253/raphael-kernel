#!/usr/bin/env bash
# =============================================================================
# build.sh — 一键编译「Droidspaces 容器 + KernelSU root」内核
# 目标机型: Redmi K20 Pro (raphael) / Xiaomi Mi 9 (cepheus) — SM8150 / msmnile / 4.14
#
#   用法（WSL / Ubuntu 22.04+ / Debian 12）:
#       ./build.sh --check      # 只做配置：克隆 + 打补丁 + 合并 config + 体检，不编译
#       ./build.sh              # 完整编译 => work/out/arch/arm64/boot/Image + AnyKernel3 zip
#       ./build.sh -j 16        # 指定并行度（默认 nproc）
#
#   常用开关:
#       --repo URL --branch BR --defconfig NAME     换内核源码/分支/基础 defconfig
#       --tree DIR                                  用已有内核树（不 clone）
#       --ksu-tag TAG                               指定 KernelSU 版本（默认 main 最新 tag）
#       --no-ksu                                    只编 Droidspaces，不要 root
#       --clang-dir DIR                             用手上已有的 clang 目录
#       --llvm                                      用 LLVM=1 + LLVM_IAS=1（老树可能编不过）
#       --gcc                                       用系统 gcc 交叉编译（aarch64-linux-gnu-）
#
#   实测基线（2026-10）:
#       repo    https://github.com/Laulan56/android_kernel_xiaomi_sm8150  branch android14
#       kernel  4.14.336 (Makefile 实测)    defconfig  raphael_stock_defconfig
#       该 defconfig 实测缺 KPROBES / SYSVIPC / PID_NS / DEVTMPFS / USER_NS / CGROUP_PIDS 等
#       => 直接编原厂内核虽然能开机，但 Droidspaces 起不了容器、KSU 也挂不上 hook
# =============================================================================
set -euo pipefail

# ---------------- 默认值 ----------------
REPO="${REPO:-https://github.com/Laulan56/android_kernel_xiaomi_sm8150.git}"
BRANCH="${BRANCH:-android14}"
DEFCONFIG="${DEFCONFIG:-raphael_stock_defconfig}"
KSU_TAG="${KSU_TAG:-main}"
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/tiann/KernelSU/refs/heads/main/kernel/setup.sh}"
CLANG_VER="${CLANG_VER:-clang-r416183b1}"
CLANG_URL_BASE="${CLANG_URL_BASE:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-qpr3-release}"
JOBS="${JOBS:-$(nproc)}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$KIT_DIR/work}"
TREE_DIR=""
OUT_REL="out"
CHECK_ONLY=0
WITH_KSU=1
TOOLCHAIN_MODE="clang"      # clang | llvm | gcc
CLANG_DIR=""
DEVICE_NAMES="raphael cepheus"

# ---------------- 参数 ----------------
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --no-ksu) WITH_KSU=0 ;;
    --llvm) TOOLCHAIN_MODE="llvm" ;;
    --gcc) TOOLCHAIN_MODE="gcc" ;;
    --repo) REPO="$2"; shift ;;
    --branch) BRANCH="$2"; shift ;;
    --defconfig) DEFCONFIG="$2"; shift ;;
    --ksu-tag) KSU_TAG="$2"; shift ;;
    --tree) TREE_DIR="$2"; shift ;;
    --out) OUT_REL="$2"; shift ;;
    --jobs|-j) JOBS="$2"; shift ;;
    --clang-dir) CLANG_DIR="$2"; shift ;;
    --work) WORK="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
  shift
done

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

# ---------------- 0. 环境自检 ----------------
need=(); for t in git make bc bison flex cpio lz4 python3 curl unzip patch; do command -v "$t" >/dev/null || need+=("$t"); done
[ ${#need[@]} -eq 0 ] || die "缺命令: ${need[*]}  （Ubuntu: sudo apt install -y build-essential git bc bison flex libssl-dev libelf-dev lz4 cpio python3 curl unzip patch）"
mkdir -p "$WORK" || { echo "建不了工作目录 $WORK"; exit 1; }
# 注意: 这里必须 mkdir 之后再 df，并且把 df 的失败吞掉 —— 以前 df 一个不存在的目录
# 会在 set -euo pipefail 下静默 exit 1（stderr 被 2>/dev/null 吃掉，日志里什么都不剩）
FREE_G="$(df -Pk "$WORK" 2>/dev/null | awk 'NR==2{print int($4/1048576)}' || true)"
FREE_G="${FREE_G:-0}"
log "工作目录: $WORK（可用 ${FREE_G}GiB）"
[ "$FREE_G" -ge 12 ] || warn "可用空间 ${FREE_G}GiB < 12GiB，4.14 全量编译建议 ≥15GiB（含源码 + out）"

# ---------------- 1. 源码 ----------------
TREE="$TREE_DIR"
if [ -z "$TREE" ]; then
  TREE="$WORK/$(basename "$BRANCH")"
  if [ -d "$TREE/.git" ]; then
    log "复用已有源码树 $TREE"
  else
    log "克隆 $REPO ($BRANCH) => $TREE"
    git clone --depth=1 -b "$BRANCH" "$REPO" "$TREE" || die "克隆失败（网络/分支名）"
  fi
fi
[ -f "$TREE/Makefile" ] || die "$TREE 不是内核源码树"
cd "$TREE"
KVER="$(awk '/^VERSION|^PATCHLEVEL|^SUBLEVEL/{printf "%s.", $3}' Makefile | sed 's/\.$//')"
log "内核基线版本: $KVER"
grep -q "CONFIG_64BIT" arch/arm64/configs/"$DEFCONFIG" 2>/dev/null || \
  [ -f arch/arm64/configs/"$DEFCONFIG" ] || die "找不到 arch/arm64/configs/$DEFCONFIG"

# ---------------- 2. 补丁 ----------------
apply_patch() {  # $1=patch 文件
  local p="$1"
  if git apply --check --reverse "$p" >/dev/null 2>&1; then
    log "补丁已存在，跳过: $(basename "$p")"
  elif git apply --check "$p" >/dev/null 2>&1; then
    git apply "$p" && log "已应用: $(basename "$p")"
  elif patch -p1 --dry-run -f <"$p" >/dev/null 2>&1; then
    patch -p1 -f <"$p" >/dev/null && log "已应用(带 fuzzy): $(basename "$p")"
  else
    warn "补丁打不上，跳过: $(basename "$p")（该树可能没这个文件，例如 4.14.336 已无 xt_qtaguid.c）"
  fi
}
log "应用 Droidspaces non-GKI 补丁"
# cgroup 文件前缀补丁：4.14/4.19 必打，否则容器里 cgroup 层级名对不上（实测在 4.14.336 上 offset +199 干净应用）
apply_patch "$KIT_DIR/patches/02.fix_restore_cgroup_file_prefix_handling_.patch"
# xt_qtaguid 崩溃补丁：只对仍然带 xt_qtaguid.c 的老树（3.18/4.4）有意义
apply_patch "$KIT_DIR/patches/01.fix_kernel_panic_in_xt_qtaguid.patch"

# ---------------- 3. KernelSU ----------------
if [ "$WITH_KSU" = 1 ]; then
  if [ -d drivers/kernelsu ] || [ -L drivers/kernelsu ]; then
    log "KernelSU 已集成，跳过"
  else
    log "集成 KernelSU ($KSU_TAG)"
    curl -LSs "$KSU_SETUP_URL" -o "$WORK/ksu-setup.sh" || die "下载 setup.sh 失败"
    sh "$WORK/ksu-setup.sh" "$KSU_TAG" || die "setup.sh 执行失败"
    [ -d drivers/kernelsu ] || die "KernelSU 未落到 drivers/kernelsu"
  fi
  # 非 GKI 4.14 只有 kprobe 一条路，KPROBES 必须开（第 4 步的 fragment 已写）
fi

# ---------------- 4. 合并 config ----------------
# 不用「make vendor/xxx.config」那条路：树里 scripts/kconfig/Makefile 的 %.config 规则是
#   merge_config.sh -m .config $(configfiles)
# 在 O=out 场景下它写的是顶层 .config，且 merge_config 对「基础 config 里没出现过的符号」
# 直接 continue 丢掉（如 IPC_NS / CFS_BANDWIDTH / KPROBE_EVENTS）。
# 所以这里走确定性路线：defconfig 生成 out/.config -> 追加 fragment（后出现的值覆盖前面的）
# -> olddefconfig 让 Kconfig 重新算依赖。
mkdir -p arch/arm64/configs/vendor
cp "$KIT_DIR/configs/droidspaces-raphael.config" arch/arm64/configs/vendor/droidspaces.config
log "生成 .config: $DEFCONFIG + droidspaces fragment"
make -s O="$OUT_REL" "$DEFCONFIG" >/dev/null 2>&1 || die "make $DEFCONFIG 失败"
CFG="$OUT_REL/.config"
[ -f "$CFG" ] || die "没生成 $CFG"
{ echo ""; echo "# ==== droidspaces fragment (appended $(date -u +%FT%TZ)) ====";
  cat arch/arm64/configs/vendor/droidspaces.config; } >> "$CFG"
make -s O="$OUT_REL" olddefconfig >"$WORK/merge.log" 2>&1 || die "olddefconfig 失败，见 $WORK/merge.log"

# ---------------- 5. 配置硬闸门（不过就自愈一次，再不过就停）----------------
check_opt() {
  local o="$1" want="$2" got
  got="$(grep -E "^${o}=|^# ${o} is not set" "$CFG" | head -1)"
  case "$want" in
    y) [ "$got" = "${o}=y" ] ;;
    n) [ "$got" = "# ${o} is not set" ] || [ -z "$got" ] ;;
    *) [ -n "$got" ] ;;
  esac
}
MUST_Y="CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE CONFIG_NAMESPACES CONFIG_PID_NS CONFIG_UTS_NS CONFIG_IPC_NS
CONFIG_SECCOMP CONFIG_SECCOMP_FILTER CONFIG_CGROUPS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS CONFIG_MEMCG
CONFIG_DEVTMPFS CONFIG_OVERLAY_FS CONFIG_TMPFS_XATTR CONFIG_NET_NS CONFIG_VETH CONFIG_BRIDGE
CONFIG_USER_NS CONFIG_MACVLAN CONFIG_IP6_NF_NAT CONFIG_KPROBES CONFIG_KALLSYMS_ALL CONFIG_MODULES"
MUST_N="CONFIG_MODULE_SIG CONFIG_ANDROID_PARANOID_NETWORK"

gate() {  # 返回缺失项数量
  local fail=0 o
  for o in $MUST_Y; do
    if check_opt "$o" y; then [ "${QUIET:-0}" = 1 ] || printf '%-34s \033[32mOK\033[0m\n' "$o"
    else printf '%-34s \033[31mMISSING\033[0m\n' "$o"; fail=$((fail+1)); fi
  done
  for o in $MUST_N; do
    if check_opt "$o" n; then [ "${QUIET:-0}" = 1 ] || printf '%-34s \033[32mOK(off)\033[0m\n' "$o"
    else printf '%-34s \033[31m应当关闭却开着\033[0m\n' "$o"; fail=$((fail+1)); fi
  done
  echo "$fail"
}

printf '%-34s %s\n' "配置项" "结果"
fail="$(gate | tail -1)"
if [ "${fail:-0}" -ne 0 ]; then
  warn "第一轮有 $fail 项没落地，追加到 .config 后 olddefconfig 兜底"
  {
    echo ""
    echo "# ---- self-heal append $(date -u +%FT%TZ) ----"
    for o in $MUST_Y; do check_opt "$o" y || echo "${o}=y"; done
    for o in $MUST_N; do check_opt "$o" n || echo "# ${o} is not set"; done
  } >> "$CFG"
  make -s O="$OUT_REL" olddefconfig >/dev/null 2>&1 || die "olddefconfig(兜底) 失败"
  printf '%-34s %s\n' "配置项(第二轮)" "结果"
  fail="$(gate | tail -1)"
fi
[ "${fail:-0}" -eq 0 ] || die "$fail 项配置仍没落地：该符号在你选的树里不存在（换树/换 defconfig），或依赖没满足，见 $CFG"
if [ "$WITH_KSU" = 1 ] && ! grep -q "CONFIG_KPROBES=y" "$CFG"; then
  warn "KPROBES 没开：KernelSU 在 4.14 上只能靠 kprobe，编出来也不会有 root"
fi
log "配置闸门全过"

# --check 到这里就停：配置已经验完，不用再下 300MB clang
if [ "$CHECK_ONLY" = 1 ]; then
  log "--check 结束（未编译）。配置产物: $TREE/$CFG"
  exit 0
fi

# ---------------- 6. 工具链 ----------------
export ARCH=arm64 SUBARCH=arm64
case "$TOOLCHAIN_MODE" in
  gcc)
    command -v aarch64-linux-gnu-gcc >/dev/null || die "装 gcc-aarch64-linux-gnu"
    export CROSS_COMPILE=aarch64-linux-gnu-
    MAKE_ARGS=(O="$OUT_REL" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
    ;;
  clang|llvm)
    if [ -n "$CLANG_DIR" ]; then CL="$CLANG_DIR"
    elif command -v clang >/dev/null && [ "$TOOLCHAIN_MODE" = clang ]; then CL="$(dirname "$(command -v clang)")"
    else
      CL="$WORK/toolchains/$CLANG_VER/bin"
    fi
    if [ ! -x "$CL/clang" ]; then
      log "下载 AOSP $CLANG_VER（约 300MB）"
      mkdir -p "$WORK/toolchains/$CLANG_VER"
      curl -LSs "$CLANG_URL_BASE/$CLANG_VER.tar.gz" -o "$WORK/$CLANG_VER.tar.gz" || die "clang 下载失败"
      tar -xf "$WORK/$CLANG_VER.tar.gz" -C "$WORK/toolchains/$CLANG_VER" || die "clang 解压失败"
    fi
    export PATH="$CL:$PATH"
    if [ "$TOOLCHAIN_MODE" = "llvm" ]; then
      MAKE_ARGS=(O="$OUT_REL" ARCH=arm64 LLVM=1 LLVM_IAS=1)
    else
      # 4.14 Qualcomm 树的老配方：clang 编译 + GNU 交叉 binutils/汇编
      command -v aarch64-linux-gnu-gcc >/dev/null || die "clang 模式仍需 gcc-aarch64-linux-gnu 提供 binutils：sudo apt install gcc-aarch64-linux-gnu"
      # arm32 交叉 gcc 只有 vdso32 会用到；宿主没有就别硬塞，否则 make 直接报 command not found
      ARM32_ARG=""
      if command -v arm-linux-gnueabi-gcc >/dev/null; then
        ARM32_ARG="CROSS_COMPILE_ARM32=arm-linux-gnueabi-"
      else
        warn "没有 arm-linux-gnueabi-gcc，跳过 CROSS_COMPILE_ARM32（ARM32 vdso 可能不编）"
      fi
      MAKE_ARGS=(O="$OUT_REL" ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu-
                 CROSS_COMPILE=aarch64-linux-gnu- $ARM32_ARG)
    fi
    ;;
esac

# ---------------- 7. 编译 ----------------
log "开始编译 Image  (jobs=$JOBS, mode=$TOOLCHAIN_MODE)"
START=$(date +%s)
set -o pipefail
make -j"$JOBS" "${MAKE_ARGS[@]}" Image 2>&1 | tee "$WORK/build.log" | grep -E "error|Error|warning: .*(implicit|incompatible)|LD |CC |AS |Kernel: arch" || true
set +o pipefail
grep -qE "^  (Image|Kernel: arch/arm64/boot/Image) is ready" "$WORK/build.log" || \
  [ -f "$OUT_REL/arch/arm64/boot/Image" ] || die "编译失败，看 $WORK/build.log（常见：clang 版本不兼容 → 换 --clang-dir / --llvm / --gcc）"
ELAPSED=$(( $(date +%s) - START ))
IMG="$TREE/$OUT_REL/arch/arm64/boot/Image"
[ -f "$IMG" ] || die "没产出 $IMG"
log "编译完成，用时 $((ELAPSED/60))m$((ELAPSED%60))s"
ls -lh "$IMG"
KREL="$(make -s O="$OUT_REL" "${MAKE_ARGS[@]}" kernelrelease 2>/dev/null | tail -1 || true)"
log "kernel release: ${KREL:-unknown}"

# ---------------- 8. AnyKernel3 ----------------
AK="$WORK/AnyKernel3"
[ -d "$AK/.git" ] || git clone --depth=1 https://github.com/Kernel-SU/AnyKernel3.git "$AK" >/dev/null 2>&1 || die "AnyKernel3 克隆失败"
cp "$IMG" "$AK/Image"
# 机型白名单 + 说明有 KSU
sed -i 's/^device.name1=.*/device.name1=raphael/' "$AK/anykernel.sh"
sed -i 's/^device.name2=.*/device.name2=cepheus/' "$AK/anykernel.sh"
grep -q '^device.name2=' "$AK/anykernel.sh" || sed -i "0,/^device.name1=/s//device.name1=raphael\ndevice.name2=cepheus/" "$AK/anykernel.sh"
sed -i 's/^do.devicecheck=.*/do.devicecheck=1/' "$AK/anykernel.sh"
sed -i 's|ksu_supported=false|ksu_supported=true|' "$AK/anykernel.sh"

ZIP="$KIT_DIR/raphael-${KREL:-4.14}-droidspaces-ksu-$(date +%Y%m%d-%H%M).zip"
( cd "$AK" && zip -r9 "$ZIP" . -x '.git/*' '.github/*' >/dev/null ) || die "打包失败"
sha256sum "$ZIP" | tee "$ZIP.sha256"
cp "$IMG" "$KIT_DIR/Image-${KREL:-4.14}"
cp "$TREE/$CFG" "$KIT_DIR/.config-${KREL:-4.14}"

cat <<EOF

================ 产物 ================
刷机包 : $ZIP
裸镜像 : $KIT_DIR/Image-${KREL:-4.14}
配置文件: $KIT_DIR/.config-${KREL:-4.14}
编译日志: $WORK/build.log

刷入（先备份 boot！）:
  adb shell "su -c 'dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-backup.img'"
  adb pull /sdcard/boot-backup.img
  然后 KernelSU 管理器 -> 安装 -> 选择 zip / 或 TWRP 刷入
======================================
EOF
