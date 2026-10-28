#!/usr/bin/env python3
"""把树里 KSU Next 专有的调用点注释掉，避免和官方 KernelSU 链接冲突。

现象：bool-x 这类的 fs/exec.c 里有 `ksu_handle_execve_ksud(...)`（Next 独有），
      换成官方 v0.9.5 后该符号不存在 -> ld.lld: undefined symbol。
做法：在 drivers/kernelsu 之外，把 ksu_handle_* 的 Next 专有调用整行注释掉。
"""
import os
import re
import sys

# 只处理 Next 专有的符号名（官方 v0.9.x 用的是 ksu_handle_execveat 等）
NEXT_ONLY = (
    'ksu_handle_execve_ksud',
    'ksu_handle_vfs_read',
    'ksu_handle_fstat',
    'ksu_handle_stat',
    'ksu_handle_devpts',
)
SKIP_DIRS = {'drivers/kernelsu', 'drivers/staging/kernelsu', 'KernelSU'}


def main():
    changed = 0
    for root, dirs, files in os.walk('.'):
        rel = root.lstrip('./')
        if any(rel.startswith(s) for s in SKIP_DIRS):
            continue
        if '/.git' in root or root.startswith('./.git'):
            continue
        for fn in files:
            if not fn.endswith(('.c', '.h')):
                continue
            path = os.path.join(root, fn)
            try:
                src = open(path, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            out = []
            hit = False
            for line in src.split('\n'):
                if (not line.lstrip().startswith('//')) and any(s + '(' in line for s in NEXT_ONLY):
                    indent = line[:len(line) - len(line.lstrip())]
                    out.append(indent + '/* kit: removed next-only call */ // ' + line.strip())
                    hit = True
                else:
                    out.append(line)
            if hit:
                open(path, 'w', encoding='utf-8').write('\n'.join(out))
                changed += 1
                print('[ksu] 注释掉 Next 专有调用:', path)
    if not changed:
        print('[ksu] 没有需要处理的 Next 调用点')
    return 0


if __name__ == '__main__':
    sys.exit(main())
