#!/usr/bin/env bash
# =============================================================================
# verify.sh — 不编译，只体检：内核版本 / 补丁能否打上 / fragment 相对 defconfig 改了什么
#
#   ./verify.sh --tree /path/to/kernel            # 体检已有源码树
#   ./verify.sh --defconfig raphael_stock_defconfig --tree ...
#   ./verify.sh                                   # 用 kit 里缓存的片段自检（无需源码树）
# =============================================================================
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE=""; DEFCONFIG="raphael_stock_defconfig"
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE="$2"; shift ;;
    --defconfig) DEFCONFIG="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac; shift
done
log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

echo "================ 1. 源码树 / 版本 ================"
if [ -n "$TREE" ]; then
  [ -f "$TREE/Makefile" ] || { echo "不是内核树: $TREE"; exit 1; }
  ( cd "$TREE" && echo "path   : $TREE" && \
    echo "base   : $(awk '/^VERSION|^PATCHLEVEL|^SUBLEVEL/{printf "%s.", $3}' Makefile | sed 's/\.$//')" && \
    echo "commit : $(git log -1 --format='%h %ad %s' --date=short 2>/dev/null || echo n/a)" )
else
  echo "未指定 --tree，跳过"
fi

echo
echo "================ 2. 补丁可打性 ================"
for p in "$KIT_DIR"/patches/*.patch; do
  n="$(basename "$p")"
  if [ -z "$TREE" ]; then echo "  $n : (无源码树，跳过)"; continue; fi
  if ( cd "$TREE" && git apply --check --reverse "$p" >/dev/null 2>&1 ); then
    printf '  %-52s \033[32m已应用\033[0m\n' "$n"
  elif ( cd "$TREE" && git apply --check "$p" >/dev/null 2>&1 ); then
    printf '  %-52s \033[32m可应用\033[0m\n' "$n"
  else
    printf '  %-52s \033[31m打不上(检查文件是否存在)\033[0m\n' "$n"
  fi
done

echo
echo "================ 3. fragment vs defconfig 差异 ================"
FRAG="$KIT_DIR/configs/droidspaces-raphael.config"
python3 - "$FRAG" "${TREE:+$TREE/arch/arm64/configs/$DEFCONFIG}" <<'PY'
import re,sys,os
frag, base = sys.argv[1], sys.argv[2] if len(sys.argv)>2 else ""
def parse(path):
    d={}
    if not path or not os.path.exists(path): return d
    for line in open(path, errors='replace'):
        line=line.strip()
        if line.startswith('#') and line.endswith('is not set'):
            d[line[2:].rsplit(' is not set',1)[0].strip()]='n'
        elif re.match(r'^CONFIG_[A-Za-z0-9_]+=', line):
            k,v=line.split('=',1); d[k]=v
    return d
f=parse(frag); b=parse(base)
if not b:
    print(f"  基线 defconfig 未提供，仅列出 fragment 共 {len(f)} 项")
    for k in sorted(f): print(f"    {k}={f[k]}")
    raise SystemExit
turned_on=[]; changed=[]; already=[]; same_off=[]
for k,v in f.items():
    cur=b.get(k,'ABSENT')
    if cur=='ABSENT': turned_on.append((k,v,'不存在'))
    elif cur=='n' and v=='y': turned_on.append((k,v,'关 -> 开'))
    elif cur!=v: changed.append((k,cur,v))
    else: same_off.append(k)
print(f"  基线 {os.path.basename(base)}: {len(b)} 项；fragment: {len(f)} 项")
print(f"  ├─ 需要新打开的: {len(turned_on)}")
for k,v,why in turned_on: print(f"  │   {k:42s} = {v:3s} ({why})")
print(f"  ├─ 值被改写的: {len(changed)}")
for k,c,v in changed: print(f"  │   {k:42s} {c} -> {v}")
print(f"  └─ 基线已一致的: {len(same_off)}")
PY

echo
echo "================ 4. 结论 ================"
cat <<'EOF'
  必须全绿的三件事:
    (a) 02 cgroup 前缀补丁可应用（4.14 上实测 offset +199 干净应用）
    (b) fragment 里 CONFIG_KPROBES 能被打开（KernelSU 4.14 只走 kprobe）
    (c) CONFIG_PID_NS / CONFIG_SYSVIPC / CONFIG_DEVTMPFS / CONFIG_IPC_NS 打开（否则 Droidspaces 起不了容器）
  完整闸门在 build.sh 第 5 步，--check 模式会真的跑一遍 kconfig 验证。
EOF
