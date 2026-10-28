#!/usr/bin/env python3
"""修 bool-x 等树里 drivers/clk/clk.c 的编译错误：`orphan_list` 未定义。

现象：开启 CONFIG_DEBUG_FS 后编译报
    drivers/clk/clk.c:3493: error: use of undeclared identifier 'orphan_list'
原因：该分支 debugfs 段里写成了 `&orphan_list`，实际全局变量叫 `clk_orphan_list`。
"""
import os
import sys

SRC = 'drivers/clk/clk.c'


def main():
    if not os.path.exists(SRC):
        return 0
    src = open(SRC, encoding='utf-8', errors='replace').read()
    if 'clk_orphan_list' not in src:
        return 0
    if '&orphan_list' not in src:
        print('[clk] 无需修正')
        return 0
    n = src.count('&orphan_list')
    src = src.replace('&orphan_list', '&clk_orphan_list')
    open(SRC, 'w', encoding='utf-8').write(src)
    print('[clk] 已修正 %d 处 &orphan_list -> &clk_orphan_list' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main())
