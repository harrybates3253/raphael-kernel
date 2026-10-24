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

# ---- 2) 新内核才有的头文件，4.14 上换成等价写法 ----
# 云端实测: feature/sucompat.c:8  fatal error: 'linux/pgtable.h' file not found
#   linux/pgtable.h 是 5.8 才拆出来的，4.14 里 pgtable 定义在 asm/pgtable.h
HEADER_MAP = {
    "linux/pgtable.h":  ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)\n#include <linux/pgtable.h>\n#else\n#include <asm/pgtable.h>\n#endif",
                         "KSU_LEGACY_INC_PGTABLE"),
    "linux/umh.h":      ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n#include <linux/umh.h>\n#else\n#include <linux/kmod.h>\n#endif",
                         "KSU_LEGACY_INC_UMH"),
    "linux/mmap_lock.h":("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)\n#include <linux/mmap_lock.h>\n#else\n#define mmap_read_lock(mm) down_read(&(mm)->mmap_sem)\n#define mmap_read_unlock(mm) up_read(&(mm)->mmap_sem)\n#define mmap_write_lock(mm) down_write(&(mm)->mmap_sem)\n#define mmap_write_unlock(mm) up_write(&(mm)->mmap_sem)\n#endif",
                         "KSU_LEGACY_INC_MMAPLOCK"),
}

import re
files = []
for dirpath, _dn, filenames in os.walk(ksu):
    for fn in filenames:
        if fn.endswith((".c", ".h")):
            files.append(os.path.join(dirpath, fn))

hdr_changed = []
for pth in files:
    txt = open(pth, encoding="utf-8", errors="replace").read()
    orig = txt
    for hdr, (repl, marker) in HEADER_MAP.items():
        if marker in txt:
            continue
        # 同时处理 <> 和 "" 两种写法
        for form in ('#include <%s>' % hdr, '#include "%s"' % hdr):
            if form in txt:
                block = "/* [%s] %s 在 4.14 上不存在 */\n#include <linux/version.h>\n%s" % (marker, hdr, repl)
                txt = txt.replace(form, block, 1)
    if txt != orig:
        open(pth, "w", encoding="utf-8").write(txt)
        hdr_changed.append(pth)

for f in hdr_changed:
    print("  header-patched:", os.path.relpath(f, root))

# ---- 2.5) 用户态拷贝函数的版本差 ----
# 云端实测: hook/syscall_event_bridge.c  implicit declaration of 'strncpy_from_user'
#           feature/sucompat.c        implicit declaration of 'strncpy_from_user_nofault'
#   -> 前者只是少 include；后者是 5.0 才有的函数，4.14 上用 strncpy_from_user 等价兜住
NOFAULT_BLOCK = """/* [ksu-legacy-shim: KSU_LEGACY_STRNCPY_NOFAULT] strncpy_from_user_nofault 是 5.0 才有的 */
#include <linux/version.h>
#include <linux/uaccess.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
#define strncpy_from_user_nofault(dst, src, count) strncpy_from_user(dst, src, count)
#endif
"""

extra = []
for pth in files:
    txt = open(pth, encoding="utf-8", errors="replace").read()
    orig = txt
    if "strncpy_from_user_nofault(" in txt and "KSU_LEGACY_STRNCPY_NOFAULT" not in txt:
        txt = NOFAULT_BLOCK + txt
    elif "strncpy_from_user(" in txt and "#include <linux/uaccess.h>" not in txt \
         and 'include "linux/uaccess.h"' not in txt:
        txt = "/* [ksu-legacy-shim: KSU_LEGACY_UACCESS_INC] */\n#include <linux/uaccess.h>\n" + txt
    if txt != orig:
        open(pth, "w", encoding="utf-8").write(txt)
        extra.append(pth)
for f in extra:
    print("  uaccess/nofault-patched:", os.path.relpath(f, root))

# ---- 3) MODULE_IMPORT_NS：谁用了就给谁在文件头定义 ----
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
print("  => symbol %d 处, header %d 处, 已存在 %d 处" % (len(changed), len(hdr_changed), len(skipped)))
