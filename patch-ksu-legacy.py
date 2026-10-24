#!/usr/bin/env python3
# =============================================================================
# patch-ksu-legacy.py — 让 KernelSU main（v3.x）能在 4.14 arm64 上编过
#
# 云端实测到的两个错（tiann/KernelSU main + Laulan56 4.14.336）:
#   hook/syscall_hook.h:11  error: unknown type name 'syscall_fn_t'
#       -> syscall_fn_t 是 4.17 才引入的 typedef；KSU 只给 x86_64 / riscv 补了，
#          arm64 依赖内核自带，4.14 上没有
#   core/init.c:253        error: a parameter list without types ...
#       -> MODULE_IMPORT_NS 宏是 5.4 才有的，4.14 里未定义 -> 被当成函数声明解析
#
# 做法: 只往源码里插最小兼容块，幂等（带 marker，重复跑不会重复插）
# 用法: python3 patch-ksu-legacy.py <kernel_root>
# =============================================================================
import os, sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
ksu = os.path.join(root, "drivers", "kernelsu")

SYS_HOOK = os.path.join(ksu, "hook", "syscall_hook.h")

# 插在 include 之后（幂等 marker: KSU_LEGACY_SYSCALL_FN_T）
FN_T_BLOCK = """#include <asm/syscall.h>
#include <linux/version.h>
/* [ksu-legacy-shim] 4.17 之前没有 syscall_fn_t；KSU 只给 x86_64/riscv 补了 typedef */
#if defined(__aarch64__) && LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
#define KSU_LEGACY_SYSCALL_FN_T 1
typedef long (*syscall_fn_t)(const struct pt_regs *);
#endif"""

# 插在文件最顶（幂等 marker: KSU_LEGACY_MODULE_IMPORT_NS）。必须放最顶，
# 因为 KSU 的 init.c 中间有 #if CONFIG_STACKPROTECTOR 块，插进去会被条件挡住。
NS_BLOCK = """/* [ksu-legacy-shim: KSU_LEGACY_MODULE_IMPORT_NS] MODULE_IMPORT_NS 是 5.4 才引入的宏 */
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)
#ifndef MODULE_IMPORT_NS
#define MODULE_IMPORT_NS(ns)
#endif
#endif
"""

changed, skipped = [], []

# ---- 1) syscall_fn_t ----
if os.path.exists(SYS_HOOK):
    src = open(SYS_HOOK, encoding="utf-8", errors="replace").read()
    if "KSU_LEGACY_SYSCALL_FN_T" in src:
        skipped.append(SYS_HOOK)
    else:
        if "#include <asm/syscall.h>" in src:
            src = src.replace("#include <asm/syscall.h>", FN_T_BLOCK, 1)
        else:
            src = FN_T_BLOCK + "\n" + src
        open(SYS_HOOK, "w", encoding="utf-8").write(src)
        changed.append(SYS_HOOK)
else:
    print("  WARN 找不到", SYS_HOOK)

# ---- 2) MODULE_IMPORT_NS：谁用了就给谁在文件头定义 ----
targets = []
for dirpath, _dirnames, filenames in os.walk(ksu):
    for fn in filenames:
        if not fn.endswith((".c", ".h")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            txt = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "MODULE_IMPORT_NS(" in txt or "MODULE_IMPORT_NS(" in txt:
            targets.append(p)

for p in targets:
    src = open(p, encoding="utf-8", errors="replace").read()
    if "KSU_LEGACY_MODULE_IMPORT_NS" in src:
        skipped.append(p)
        continue
    open(p, "w", encoding="utf-8").write(NS_BLOCK + src)
    changed.append(p)

for f in changed:
    print("  patched:", os.path.relpath(f, root))
for f in skipped:
    print("  skip   :", os.path.relpath(f, root))
print("  => %d 处插入, %d 处已存在" % (len(changed), len(skipped)))
