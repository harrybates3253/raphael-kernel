#!/usr/bin/env python3
"""把小米官方 goodix_ta 指纹驱动换进来（cepheus-q-oss，4.14）。

原因：本树自带的 gf_spi.c 只实现 6 个 ioctl（INIT/IRQ/RESET/POWER），
      而 ROM 的指纹 HAL（libgf_hal.so）还要用 CHIP_INFO、NAV_EVENT、
      INPUT_KEY_EVENT、ENTER_SLEEP_MODE、GET_FW_INFO、SPI_CLK 等，
      缺一个就会导致「能感知按压但录不进/认不出」。
      小米官方驱动 15+ 个 ioctl 齐全，且 DT 属性名（fp-gpio-pwr /
      goodix,gpio-irq / goodix,gpio-reset）与本机 dtbo 完全一致。
"""
import os
import shutil
import sys

DST_DIR = 'drivers/input/fingerprint/goodix_ta'
SRC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'goodix_ta')
FILES = ('gf_spi.c', 'gf_spi.h', 'netlink.c', 'platform.c')
MAKEFILE = os.path.join(DST_DIR, 'Makefile')
NEW_OBJS = 'obj-$(CONFIG_FINGERPRINT_GOODIX_TA) += gf_spi.o platform.o netlink.o'


def main():
    if not os.path.isdir(DST_DIR):
        print('[goodix] 目标目录不存在，跳过', file=sys.stderr)
        return 1
    missing = [f for f in FILES if not os.path.exists(os.path.join(SRC_DIR, f))]
    if missing:
        print('[goodix] 缺少源文件 %s，跳过' % missing, file=sys.stderr)
        return 1

    marker = os.path.join(DST_DIR, 'platform.c')
    if os.path.exists(marker) and 'goodix_ta' in open(marker, encoding='utf-8', errors='replace').read():
        print('[goodix] 已经是小米驱动，跳过')
        return 0

    for f in FILES:
        shutil.copy2(os.path.join(SRC_DIR, f), os.path.join(DST_DIR, f))

    with open(MAKEFILE, 'w', encoding='utf-8') as fh:
        fh.write(NEW_OBJS + '\n')

    print('[goodix] 已替换为小米官方 goodix_ta 驱动（4 个文件 + Makefile）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
