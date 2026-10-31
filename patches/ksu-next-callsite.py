#!/usr/bin/env python3
"""把树里 KSU Next 专有的调用替换成 0，避免与官方 KernelSU 链接冲突。

现象：bool-x 的 fs/exec.c、fs/read_write.c 调用了 Next 独有符号
      （ksu_handle_execve_ksud / ksu_handle_vfs_read ...），换官方 v0.9.5 后
      ld.lld 报 undefined symbol；简单注释行会破坏多行调用/if 结构。

做法：做括号配对的替换——把 `sym( ... )` 整个调用表达式替换成 `0`，
      语法保持合法（`if (0)`、`(void)0;`、`x = 0;` 都能编）。
"""
import os
import re
import sys

NEXT_ONLY = (
    'ksu_handle_execve_ksud',      # Next 专有（官方用 ksu_handle_execveat）
)
SKIP_PREFIX = ('./drivers/kernelsu', './drivers/staging/kernelsu', './KernelSU', './.git')


def strip_calls(src):
    changed = 0
    for sym in NEXT_ONLY:
        i = 0
        while True:
            i = src.find(sym + '(', i)
            if i < 0:
                break
            # 跳过声明行（extern ...）
            line_start = src.rfind('\n', 0, i) + 1
            prefix = src[line_start:i]
            if 'extern' in prefix:
                i += len(sym)
                continue
            # 找配对右括号
            depth = 0
            j = src.find('(', i)
            k = j
            while k < len(src):
                ch = src[k]
                if ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            if k >= len(src):
                break
            src = src[:i] + '0' + src[k + 1:]
            changed += 1
            i += 1
    return src, changed


HOOK_BOOLS = ('ksu_vfs_read_hook', 'ksu_execveat_hook', 'ksu_input_hook',
              'ksu_init_rc_hook', 'ksu_input_event_hook')


def stub_hook_bools(src):
    """把 `extern bool ksu_xxx_hook [__read_mostly];` 换成文件内 static const。

    实际写法带属性：`extern bool ksu_vfs_read_hook __read_mostly;`
    """
    changed = 0
    out = []
    pat = re.compile(r'^(?P<indent>\s*)extern\s+bool\s+(?P<name>' + '|'.join(HOOK_BOOLS) + r')\s*(?:__read_mostly)?\s*;\s*$')
    seen = set()
    for line in src.split('\n'):
        m = pat.match(line)
        if m:
            name = m.group('name')
            if name in seen:
                # 同一文件里重复声明：直接删掉，避免 redefinition
                out.append('%s/* kit: duplicate decl of %s removed */' % (m.group('indent'), name))
            else:
                seen.add(name)
                out.append('%sstatic const bool %s __maybe_unused = false; /* kit: stub */'
                           % (m.group('indent'), name))
            changed += 1
        else:
            out.append(line)
    return '\n'.join(out), changed


def main():
    total = 0
    for root, dirs, files in os.walk('.'):
        if any(root.startswith(p) for p in SKIP_PREFIX):
            continue
        for fn in files:
            if not fn.endswith(('.c', '.h')):
                continue
            path = os.path.join(root, fn)
            try:
                src = open(path, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            if not any(s in src for s in NEXT_ONLY) and not any(h in src for h in HOOK_BOOLS):
                continue
            new, n = strip_calls(src)
            n2 = 0
            if n:
                open(path, 'w', encoding='utf-8').write(new)
                total += n + n2
                print('[ksu] %-40s 调用 %d 处 / hook 变量 %d 处' % (path, n, n2))
    if not total:
        print('[ksu] 没有需要处理的 Next 调用点')
    return 0


if __name__ == '__main__':
    sys.exit(main())
