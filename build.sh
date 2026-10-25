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
KSU_TAG="${KSU_TAG:-master}"
# 默认用 backslashxx/KernelSU（即社区里说的 "KernelSU-by-xx"）：它带 kernel/kernel_compat.h，
# 官方 tiann main 的 LSM hook / syscall dispatcher / selinux_state 全是 4.17+ 的写法，4.14 编不过
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/backslashxx/KernelSU/refs/heads/master/kernel/setup.sh}"
CLANG_VER="${CLANG_VER:-clang-r416183b1}"
CLANG_URL_BASE="${CLANG_URL_BASE:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-qpr3-release}"
JOBS="${JOBS:-$(nproc)}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$KIT_DIR/work}"
TREE_DIR=""
DEFCONFIG_FILE=""
DROP_TECHPACK="${DROP_TECHPACK:-0}"
USE_LLD="${USE_LLD:-0}"
SLIM="${SLIM:-0}"
BASELINE="${BASELINE:-0}"
TINY="${TINY:-0}"
FORCE_AOSP_CLANG="${FORCE_AOSP_CLANG:-0}"
USE_IAS="${USE_IAS:-0}"
NO_MEDIA="${NO_MEDIA:-0}"
LOCALVERSION="${LOCALVERSION:-}"
NO_MODVERSIONS="${NO_MODVERSIONS:-0}"
BUILD_TARGET="${BUILD_TARGET:-Image}"
KERNEL_BLOB="${KERNEL_BLOB:-Image}"
OUT_REL="out"
CHECK_ONLY=0
WITH_KSU=1
TOOLCHAIN_MODE="clang"      # clang | llvm | gcc
CLANG_DIR=""
DEVICE_NAMES="raphael cepheus"
KSU_FALLBACKS="${KSU_FALLBACKS:-}"   # main 在 4.14 上编不过时依次尝试

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
    --defconfig-file) DEFCONFIG_FILE="$2"; shift ;;
    --drop-techpack) DROP_TECHPACK=1 ;;
    --lld) USE_LLD=1 ;;
    --slim) SLIM=1 ;;
    --baseline) BASELINE=1 ;;
    --tiny) TINY=1 ;;
    --aosp-clang) FORCE_AOSP_CLANG=1 ;;
    --ias) USE_IAS=1 ;;
    --no-media) NO_MEDIA=1 ;;
    --localversion) LOCALVERSION="$2"; shift ;;
    --target) BUILD_TARGET="$2"; shift ;;
    --kernel-blob) KERNEL_BLOB="$2"; shift ;;
    --no-modversions) NO_MODVERSIONS=1 ;;
    --ksu-tag) KSU_TAG="$2"; shift ;;
    --ksu-fallbacks) KSU_FALLBACKS="$2"; shift ;;
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

# ARCH 必须在生成 .config 之前就 export：make raphael_stock_defconfig 会用 SRCARCH 去
# arch/$(SRCARCH)/configs/ 找文件，不设 ARCH 就变成 arch/x86/configs -> 直接报 No rule
export ARCH=arm64 SUBARCH=arm64

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
# 用外部 config 当基线（例如从工作机的 /proc/config.gz 拉出来的 .config）
# 注意：必须在 cd 进树之后再做，否则 cp 到的是 work 目录
if [ -n "$DEFCONFIG_FILE" ]; then
  [ -f "$KIT_DIR/$DEFCONFIG_FILE" ] && DEFCONFIG_FILE="$KIT_DIR/$DEFCONFIG_FILE"
  [ -f "$DEFCONFIG_FILE" ] || die "找不到 $DEFCONFIG_FILE"
  DEFCONFIG="raphael_custom_defconfig"
  cp "$DEFCONFIG_FILE" "arch/arm64/configs/$DEFCONFIG"
  log "用外部 config 作基线: $DEFCONFIG_FILE -> arch/arm64/configs/$DEFCONFIG"
fi
KVER="$(awk '/^VERSION|^PATCHLEVEL|^SUBLEVEL/{printf "%s.", $3}' Makefile | sed 's/\.$//')"
log "内核基线版本: $KVER"
grep -q "CONFIG_64BIT" arch/arm64/configs/"$DEFCONFIG" 2>/dev/null || \
  [ -f arch/arm64/configs/"$DEFCONFIG" ] || die "找不到 arch/arm64/configs/$DEFCONFIG"

# 有些树（HeliumStudio 的 oss-base）scripts/dtc 里有 yamltree.c，但 Makefile 没链 -lyaml
# 会让 host 工具 dtc 链接失败（undefined reference to yaml_*）。这里补一行。
if [ -f scripts/dtc/yamltree.c ] && ! grep -q "HOSTLOADLIBES_dtc" scripts/dtc/Makefile 2>/dev/null; then
  echo 'HOSTLOADLIBES_dtc += -lyaml' >> scripts/dtc/Makefile
  echo 'HOSTLOADLIBES_dtc-lexer += -lyaml' >> scripts/dtc/Makefile
  log "已给 scripts/dtc/Makefile 补 -lyaml"
fi

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

# ---------------- 2.5 可选：砍掉 techpack（高通 camera/audio，Image 里能占 15MB）----------------
if [ "$DROP_TECHPACK" = 1 ] && [ -d techpack ]; then
  if grep -qE "^drivers-y.*techpack/" Makefile; then
    sed -i '/^drivers-y/s# techpack/##' Makefile
    log "已从顶层 Makefile 移除 techpack/（体积优化）"
  fi
  grep -n "^drivers-y" Makefile | head -1
fi

# ---------------- 3. KernelSU ----------------
# 做成函数是因为 main 在 4.14 上编不过时要能原地换 tag（见第 7 段 smoke）
setup_ksu() {   # $1 = tag/分支
  local tag="$1"

  # A) 树里自带 KernelSU 子模块（iatbsky/Rikka 的树就是这种：drivers/staging/kernelsu
  #    指向 tiann/KernelSU 的某个 pin 住的 commit）。这条路最稳：KSU 版本就是
  #    “原始能开机的内核”用的那一个，不用 setup.sh，也不会和树里的 Kconfig 打架。
  if [ -f .gitmodules ] && grep -qi "kernelsu" .gitmodules; then
    log "树内带 KernelSU 子模块，初始化子模块"
    git submodule update --init --recursive >/dev/null 2>&1 || \
      git submodule update --init --recursive --depth 1 >/dev/null 2>&1 || \
      die "子模块初始化失败（.gitmodules 里有 kernelsu）"
    local sub
    sub="$(git config -f .gitmodules --get-regexp 'path' | awk '/kernelsu/{print $2; exit}')"
    log "KSU 子模块: ${sub:-drivers/staging/kernelsu} @ $(git -C "${sub:-.}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    KSU_USED="submodule:$(git -C "${sub:-.}" rev-parse --short HEAD 2>/dev/null || echo pinned)"
    KSU_MODE="submodule"
    return 0
  fi
  if [ -d KernelSU/.git ]; then
    log "切换 KernelSU -> $tag"
    ( cd KernelSU
      git fetch --tags --quiet 2>/dev/null || true
      # -f：上次打的兼容补丁是本地改动，不强制丢弃会导致 checkout 失败
      git checkout -q -f "$tag" 2>/dev/null || \
      git checkout -q -f -B "$tag" "origin/$tag" 2>/dev/null || \
      git checkout -q -f -B "$tag" "refs/tags/$tag" 2>/dev/null || \
        { echo "  切不到 $tag（现有 tag: $(git tag | tail -5 | tr '\n' ' ')）"; exit 1; }
      git log -1 --format='  当前 KernelSU: %h %s' ) || return 1
  else
    log "集成 KernelSU ($tag)"
    curl -LSs "$KSU_SETUP_URL" -o "$WORK/ksu-setup.sh" || return 1
    sh "$WORK/ksu-setup.sh" "$tag" || return 1
    [ -L drivers/kernelsu ] || [ -d drivers/kernelsu ] || return 1
  fi
  # 分支自带 kernel_compat.h（backslashxx 分支）就不用我们的 shim，避免重复 typedef
  if [ -f drivers/kernelsu/kernel_compat.h ]; then
    log "KSU 自带 kernel/kernel_compat.h，跳过 4.14 shim"
  else
    python3 "$KIT_DIR/patch-ksu-legacy.py" "$TREE" >"$WORK/ksu-shim.log" 2>&1 && \
      log "KSU 兼容补丁: $(tail -1 "$WORK/ksu-shim.log")" || warn "KSU 兼容补丁有告警，见 $WORK/ksu-shim.log"
  fi
  return 0
}

KSU_USED=""
KSU_MODE="external"
# 树内自带 KSU 子模块时，无论要不要 KSU 都得把子模块拉下来，
# 否则 drivers/staging/Kconfig 里的 source 指向空目录，连 defconfig 都过不去
if [ -f .gitmodules ] && grep -qi "kernelsu" .gitmodules; then
  log "初始化树内 KernelSU 子模块（只需要其中的 Kconfig 存在）"
  git submodule update --init --recursive >/dev/null 2>&1 || \
    git submodule update --init --recursive --depth 1 >/dev/null 2>&1 || warn "子模块初始化失败"
  _sub="$(git config -f .gitmodules --get-regexp path | awk '/kernelsu/{print $2; exit}')"
  log "子模块: ${_sub:-?} @ $(git -C "${_sub:-.}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

if [ "$WITH_KSU" = 1 ]; then
  setup_ksu "$KSU_TAG" || die "KernelSU($KSU_TAG) 集成失败"
  KSU_USED="$KSU_TAG"
fi

# ---------------- 4. 合并 config ----------------
# 不用「make vendor/xxx.config」那条路：树里 scripts/kconfig/Makefile 的 %.config 规则是
#   merge_config.sh -m .config $(configfiles)
# 在 O=out 场景下它写的是顶层 .config，且 merge_config 对「基础 config 里没出现过的符号」
# 直接 continue 丢掉（如 IPC_NS / CFS_BANDWIDTH / KPROBE_EVENTS）。
# 所以这里走确定性路线：defconfig 生成 out/.config -> 追加 fragment（后出现的值覆盖前面的）
# -> olddefconfig 让 Kconfig 重新算依赖。
mkdir -p arch/arm64/configs/vendor
if [ "$BASELINE" = 1 ]; then
  # 纯基线，只补两件“不补就编不动”的东西：
  #   1) 三个无默认值的 int（否则 silentoldconfig aborted）
  #   2) 树内 KSU 需要 KPROBES=n（否则 ksud.c 不定义 hook bools）
  cat > arch/arm64/configs/vendor/droidspaces.config <<'BASECFG'
CONFIG_LITTLE_CPU_MASK=15
CONFIG_BIG_CPU_MASK=112
CONFIG_PRIME_CPU_MASK=128
# CONFIG_KPROBES is not set
BASECFG
  log "baseline 模式：不叠加 Droidspaces fragment（只量体积）"
else
cp "$KIT_DIR/configs/droidspaces-raphael.config" arch/arm64/configs/vendor/droidspaces.config
fi
if [ "$WITH_KSU" = 0 ]; then
  { echo ""; echo "# ---- no-ksu: 子模块在，但不启用 ----"; echo "# CONFIG_KSU is not set"; } \
    >> arch/arm64/configs/vendor/droidspaces.config
fi
# CPU mask 三项在不同树里类型不同（int vs string），基础 defconfig 已给值时不要覆盖
if grep -qE '^CONFIG_(LITTLE|BIG|PRIME)_CPU_MASK=' "$OUT_REL/.config" 2>/dev/null; then
  sed -i -e '/^CONFIG_LITTLE_CPU_MASK=/d' -e '/^CONFIG_BIG_CPU_MASK=/d' -e '/^CONFIG_PRIME_CPU_MASK=/d' \
    arch/arm64/configs/vendor/droidspaces.config
  log "基础 config 已带 CPU mask，fragment 中对应三行已移除"
fi
if [ -n "$LOCALVERSION" ]; then
  cat >> arch/arm64/configs/vendor/droidspaces.config <<LOCVER

# ---- 对齐 vermagic：让 /vendor/lib/modules 下的厂商模块能被加载 ----
CONFIG_LOCALVERSION="$LOCALVERSION"
# CONFIG_LOCALVERSION_AUTO is not set
LOCVER
  log "已设置 CONFIG_LOCALVERSION=\"$LOCALVERSION\"（对齐厂商模块 vermagic）"
fi
if [ "$NO_MODVERSIONS" = 1 ]; then
  cat >> arch/arm64/configs/vendor/droidspaces.config <<NOMV

# ---- 关掉 MODVERSIONS：不同编译器产出的符号 CRC 不可能与厂商模块一致 ----
# CONFIG_MODVERSIONS is not set
NOMV
  log "已关闭 CONFIG_MODVERSIONS"
fi
if [ "$NO_MEDIA" = 1 ]; then
  cat >> arch/arm64/configs/vendor/droidspaces.config <<'NOMEDIACFG'

# ---- no-media: 关掉 camera/vidc/tuners（image_size 瘦身用）----
# CONFIG_MEDIA_SUPPORT is not set
# CONFIG_MSM_VIDC_V4L2 is not set
# CONFIG_MSM_VIDC_GOVERNORS is not set
NOMEDIACFG
  log "no-media 模式：已关闭 MEDIA_SUPPORT / MSM_VIDC"
fi
if [ "$SLIM" = 1 ]; then
  # 体积急救：关掉调试基础设施（对日常使用无影响），目标砍 8MB 到 32MiB 以下
  cat >> arch/arm64/configs/vendor/droidspaces.config <<'SLIMCFG'

# ---- slim: 调试基础设施全关（不影响正常使用，纯粹为了 Image 体积）----
# CONFIG_FTRACE is not set
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_DYNAMIC_FTRACE is not set
# CONFIG_STACK_TRACER is not set
# CONFIG_IRQSOFF_TRACER is not set
# CONFIG_SCHED_TRACER is not set
# CONFIG_FTRACE_SYSCALLS is not set
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_DEBUG_FS is not set
# CONFIG_LOCKDEP is not set
# CONFIG_PROVE_LOCKING is not set
# CONFIG_DEBUG_SPINLOCK is not set
# CONFIG_DEBUG_MUTEXES is not set
# CONFIG_DEBUG_ATOMIC_SLEEP is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_DEBUG_BUGVERBOSE is not set
# CONFIG_BPF_SYSCALL is not set
# CONFIG_KPROBE_EVENTS is not set
SLIMCFG
  log "slim 模式：已追加关闭 FTRACE/DEBUG_KERNEL/LOCKDEP/DEBUG_FS 等"
fi
if [ "${KSU_MODE:-external}" = "submodule" ]; then
  # 树内这版 KSU 的 ksud.c 是这么写的：
  #   #ifdef CONFIG_KPROBES ... static work_struct ...  #else bool ksu_vfs_read_hook/... #endif
  # 也就是说开了 KPROBES 就【不定义】那三个 bool，而树里 fs/read_write.c、fs/exec.c、
  # input.c 是无条件引用它们的 -> 链接 undefined reference。Rikka 本人必然是 KPROBES=n 编的。
  sed -i -e '/^CONFIG_KPROBES=/d' -e '/^CONFIG_HAVE_KPROBES=/d' -e '/^CONFIG_KPROBE_EVENTS=/d' \
    arch/arm64/configs/vendor/droidspaces.config
  { echo ""; echo "# 树内 KSU 走 manual hook（ksud.c 的 bools），必须关 KPROBES"; echo "# CONFIG_KPROBES is not set"; } \
    >> arch/arm64/configs/vendor/droidspaces.config
  log "检测到树内 KSU：fragment 已关闭 KPROBES（避免 ksud.c 不定义 hook bools）"
fi
log "生成 .config: $DEFCONFIG + droidspaces fragment"
if ! make O="$OUT_REL" "$DEFCONFIG" >"$WORK/defconfig.log" 2>&1; then
  echo "================ make $DEFCONFIG 失败，输出如下 ================"
  tail -40 "$WORK/defconfig.log" || true
  die "make $DEFCONFIG 失败（上面是 make 的原始输出）"
fi
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
CONFIG_USER_NS CONFIG_MACVLAN CONFIG_IP6_NF_NAT CONFIG_KALLSYMS_ALL CONFIG_MODULES"
if [ "${KSU_MODE:-external}" != "submodule" ]; then
  MUST_Y="$MUST_Y CONFIG_KPROBES"
else
  MUST_Y="$MUST_Y CONFIG_KSU"
fi
MUST_N="CONFIG_MODULE_SIG CONFIG_ANDROID_PARANOID_NETWORK"
# int 型、无默认值的符号：空值会让 silentoldconfig 直接 aborted
MUST_SET="CONFIG_LITTLE_CPU_MASK CONFIG_BIG_CPU_MASK CONFIG_PRIME_CPU_MASK"

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
  for o in $MUST_SET; do
    if ! grep -qE "^${o}=|^# ${o} is not set" "$CFG"; then
      [ "${QUIET:-0}" = 1 ] || printf '%-34s \033[33mSKIP(树里没有)\033[0m\n' "$o"
    elif grep -qE "^${o}=[^\"]*[0-9]" "$CFG"; then
      [ "${QUIET:-0}" = 1 ] || printf '%-34s \033[32mOK(set)\033[0m\n' "$o"
    else printf '%-34s \033[31m空值(会卡 silentoldconfig)\033[0m\n' "$o"; fail=$((fail+1)); fi
  done
  echo "$fail"
}

if [ "$BASELINE" = 1 ]; then
  log "baseline 模式：跳过配置闸门"
  fail=0
else
printf '%-34s %s\n' "配置项" "结果"
gate > "$WORK/gate.log" 2>&1
fail="$(tail -1 "$WORK/gate.log")"
sed '$d' "$WORK/gate.log"
fi
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
  gate > "$WORK/gate.log" 2>&1
  fail="$(tail -1 "$WORK/gate.log")"
  sed '$d' "$WORK/gate.log" 
fi
[ "${fail:-0}" -eq 0 ] || die "$fail 项配置仍没落地：$(grep -E 'MISSING|应当关闭|空值' "$WORK/gate.log" | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ';')  （该符号在你选的树里不存在或依赖没满足，见 $CFG）"
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
log "ARCH=$ARCH SUBARCH=$SUBARCH"
case "$TOOLCHAIN_MODE" in
  gcc)
    command -v aarch64-linux-gnu-gcc >/dev/null || die "装 gcc-aarch64-linux-gnu"
    export CROSS_COMPILE=aarch64-linux-gnu-
    MAKE_ARGS=(O="$OUT_REL" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
    ;;
  clang|llvm)
    if [ -n "$CLANG_DIR" ]; then CL="$CLANG_DIR"
    elif [ "$FORCE_AOSP_CLANG" = 1 ]; then CL="$WORK/toolchains/$CLANG_VER/bin"
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
      if [ "$USE_IAS" = 1 ]; then
        KCFLAGS="$KCFLAGS -fintegrated-as"
        log "启用 clang 集成汇编器 (-fintegrated-as)"
      fi
      if [ "$USE_LLD" = 1 ]; then
        # 和 Rikka 那颗一致：clang + LLD（他的 Image 28.1MiB，我们是 GNU ld 出 38MiB）
        MAKE_ARGS=(O="$OUT_REL" ARCH=arm64 CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
                   OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
                   CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- $ARM32_ARG)
        log "使用 LLD 链接"
      else
        MAKE_ARGS=(O="$OUT_REL" ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu-
                   CROSS_COMPILE=aarch64-linux-gnu- $ARM32_ARG)
      fi
    fi
    ;;
esac

# ---------------- 7. 编译 ----------------
# 4.14.336 的 Makefile 里 backport 了一批 `-Werror=...`（strict-prototypes /
# incompatible-pointer-types / implicit-int / designated-init / date-time），
# 而 Qualcomm 这堆 2019 年的厂商代码（如 xiaomi_touch.c 的 `struct class *f()`）
# 根本没按这些规矩写 -> 直接报 error。
# KCFLAGS 在 Makefile 第 1037 行才拼进 KBUILD_CFLAGS，位置在那些 -Werror 之后，
# 所以 `-Wno-error=xxx` 能盖住它们，且不用改源码。
export KCFLAGS="${KCFLAGS:--Wno-error=strict-prototypes -Wno-error=incompatible-pointer-types -Wno-error=implicit-int}"
if [ "$TINY" = 1 ]; then
  # -Oz + 去掉 unwind 表：clang 下通常能再省 10~15%
  KCFLAGS="$KCFLAGS -Oz -fno-asynchronous-unwind-tables -fno-unwind-tables"
  log "tiny 模式：追加 -Oz / -fno-unwind-tables"
fi
log "KCFLAGS=$KCFLAGS"

# 先单独编 KSU 子目录（1~2 分钟），KSU main 的 LSM hook / syscall dispatcher 是按
# 4.17+ 的 security_hook_heads(hlist) 写的，4.14 上是 list_head，语义级不兼容 ->
# 与其硬改，不如自动回落到老版本 KSU（v1.0.5 那代就是给 4.14 写的）
# KSU 的源码目录随树而异：常规是 drivers/kernelsu（setup.sh 建的符号链接），
# Rikka 的树是 drivers/staging/kernelsu（git submodule）。smoke 要编对目录名。
KSU_BUILD_DIR=""
# 三选一：子模块的 kernel/ 子目录 / 子模块根 / setup.sh 建的 drivers/kernelsu
if [ -f drivers/staging/kernelsu/kernel/Makefile ]; then
  KSU_BUILD_DIR="drivers/staging/kernelsu/kernel/"
elif [ -f drivers/kernelsu/Makefile ]; then
  KSU_BUILD_DIR="drivers/kernelsu/"
fi

smoke_ksu() {   # $1 = 版本标签（仅用于打印）
  log "单独编 security/selinux + ${KSU_BUILD_DIR:-drivers/kernelsu/}（当前 $1，2~3 分钟）"
  # 子目录单编没有顶层 vmlinux 那套生成物，先补 prepare + include/generated/compile.h
  make -s -j"$JOBS" "${MAKE_ARGS[@]}" prepare >/dev/null 2>&1 || true
  make -s -j"$JOBS" "${MAKE_ARGS[@]}" include/generated/compile.h >/dev/null 2>&1 || true
  # 先编 selinux：KSU 的 infra/file_wrapper.c 会 include selinux 内部头，
  # 而 flask.h 是编 security/selinux 时才生成的；只编 KSU 会假报 flask.h not found
  if ! make -j"$JOBS" "${MAKE_ARGS[@]}" security/selinux/ >"$WORK/ksu-smoke.log" 2>&1; then
    echo "---------------- security/selinux 编不过（smoke 前置失败） ----------------"
    grep -nE "error:|fatal error|\*\*\*" "$WORK/ksu-smoke.log" | tail -15 || true
    return 1
  fi
  if make -j"$JOBS" "${MAKE_ARGS[@]}" "$KSU_BUILD_DIR" >>"$WORK/ksu-smoke.log" 2>&1; then
    log "KSU($1) 子目录编译通过"
    return 0
  fi
  echo "---------------- KSU($1) 编译错误 ----------------"
  head -40 "$WORK/ksu-smoke.log" || true
  echo "  ..."
  grep -nE "error:|fatal error|\*\*\*|Kconfig|Configuration" "$WORK/ksu-smoke.log" | tail -25 || true
  # 只因为「子目录单编缺生成物」而挂（compile.h / flask.h），不算 KSU 的锅，放行去全量编
  if grep -qE "generated/compile\.h|'flask\.h'" "$WORK/ksu-smoke.log" && \
     ! grep -qE "error:" <(grep -vE "generated/compile\.h|flask\.h" "$WORK/ksu-smoke.log"); then
    warn "smoke 只缺生成物（compile.h/flask.h），判定为不确定，直接进全量编译"
    return 0
  fi
  return 1
}

if [ "$WITH_KSU" = 1 ]; then
  if ! smoke_ksu "$KSU_USED"; then
    for T in $KSU_FALLBACKS; do
      log "KernelSU $KSU_USED 编不过，换 $T 重试"
      if setup_ksu "$T"; then
        make -s O="$OUT_REL" olddefconfig >/dev/null 2>&1 || true
        if smoke_ksu "$T"; then KSU_USED="$T"; break; fi
      fi
    done
    if ! smoke_ksu "$KSU_USED"; then
      die "KSU 各版本都编不过（$KSU_TAG / $KSU_FALLBACKS），完整日志 $WORK/ksu-smoke.log"
    fi
  fi
  log "最终使用的 KernelSU: $KSU_USED"
fi

IMG="$TREE/$OUT_REL/arch/arm64/boot/$KERNEL_BLOB"
log "开始编译 $BUILD_TARGET  (jobs=$JOBS, mode=$TOOLCHAIN_MODE, blob=$KERNEL_BLOB)"
START=$(date +%s)
set -o pipefail
make -j"$JOBS" "${MAKE_ARGS[@]}" "$BUILD_TARGET" 2>&1 | tee "$WORK/build.log" | grep -E "error|Error|warning: .*(implicit|incompatible)|LD |CC |AS |Kernel: arch" || true
set +o pipefail
if ! grep -qE "is ready" "$WORK/build.log" && [ ! -f "$IMG" ]; then
  echo "================ build.log 里的错误行 ================"
  grep -nE "error:|Error [0-9]|\*\*\*|undefined reference|No rule|not found" "$WORK/build.log" | tail -40 || true
  echo "================ build.log 最后 120 行 ================"
  tail -120 "$WORK/build.log" || true
  echo "======================================================"
  die "编译失败（上面的错误行就是真因；完整日志 $WORK/build.log，也随 artifact 上传）"
fi
ELAPSED=$(( $(date +%s) - START ))
[ -f "$IMG" ] || die "没产出 $IMG"
log "编译完成，用时 $((ELAPSED/60))m$((ELAPSED%60))s"
ls -lh "$IMG"
KREL="$(make -s O="$OUT_REL" "${MAKE_ARGS[@]}" kernelrelease 2>/dev/null | tail -1 || true)"
log "kernel release: ${KREL:-unknown}"

# ---------------- 8. AnyKernel3 ----------------
AK="$WORK/AnyKernel3"
[ -d "$AK/.git" ] || git clone --depth=1 https://github.com/Kernel-SU/AnyKernel3.git "$AK" >/dev/null 2>&1 || die "AnyKernel3 克隆失败"
# 实机 boot.img 里 kernel 是 gzip（1f8b）；raw 44MB Image 直接塞进去
# 有可能超过 bootloader 的 kernel 缓冲上限 -> 卡 logo 重启。这里统一压成 Image.gz
case "$KERNEL_BLOB" in
  *.gz-dtb|*.gz) cp "$IMG" "$AK/$(basename "$KERNEL_BLOB")" ;;   # 已经自带 gz(+dtb)
  *)             gzip -9 -n -c "$IMG" > "$AK/Image.gz" ;;
esac
ls -lh "$AK/Image.gz"
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
