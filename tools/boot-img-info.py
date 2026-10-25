#!/usr/bin/env python3
# =============================================================================
# boot-img-info.py — 读 Android boot.img 头，算打包后总大小，判断会不会超分区
#   用法: python3 boot-img-info.py boot.img [partition_size_bytes]
#   例:   python3 boot-img-info.py boot-now.img 67108864
# =============================================================================
import struct
import sys

PATH = sys.argv[1]
PART = int(sys.argv[2]) if len(sys.argv) > 2 else None

data = open(PATH, "rb").read()
MAGIC = b"ANDROID!"
if not data.startswith(MAGIC):
    print("不是 Android boot image（magic 不符），前 16 字节:", data[:16].hex())
    sys.exit(1)

kernel_size = struct.unpack_from("<I", data, 8)[0]
ramdisk_size = struct.unpack_from("<I", data, 16)[0]
second_size = struct.unpack_from("<I", data, 24)[0]
page_size = struct.unpack_from("<I", data, 36)[0]
header_version = struct.unpack_from("<I", data, 40)[0]
os_version = struct.unpack_from("<I", data, 44)[0]
name = data[48:64].split(b"\x00")[0].decode("ascii", "replace")
cmdline = data[64:64 + 512].split(b"\x00")[0].decode("ascii", "replace")
extra = data[608:608 + 1024].split(b"\x00")[0].decode("ascii", "replace")

dtb_size = 0
dtb_addr = 0
if header_version >= 2:
    dtb_size = struct.unpack_from("<I", data, 1636)[0]
    dtb_addr = struct.unpack_from("<Q", data, 1640)[0]


def align(n, p):
    return (n + p - 1) // p * p if n else 0


total = align(page_size, page_size) + align(kernel_size, page_size) + \
    align(ramdisk_size, page_size) + align(second_size, page_size) + align(dtb_size, page_size)

print("file            : %s" % PATH)
print("file size       : %d bytes (%.1f MiB)" % (len(data), len(data) / 1048576))
print("header version  : %d" % header_version)
print("page size       : %d" % page_size)
print("name            : %s" % name)
print("kernel_size     : %d bytes (%.1f MiB)" % (kernel_size, kernel_size / 1048576))
print("ramdisk_size    : %d bytes (%.1f MiB)" % (ramdisk_size, ramdisk_size / 1048576))
print("second_size     : %d bytes" % second_size)
print("dtb_size        : %d bytes" % dtb_size)
print("放得下时总大小  : %d bytes (%.1f MiB)" % (total, total / 1048576))
if PART:
    print("分区大小        : %d bytes (%.1f MiB)" % (PART, PART / 1048576))
    print("余量            : %d bytes (%.1f MiB)  %s" % (
        PART - total, (PART - total) / 1048576, "OK" if total <= PART else "!! 放不下 !!"))
    # 我们的内核 44.7MB 替换进去会怎样
    OUR_KERNEL = 44779536
    new_total = align(page_size, page_size) + align(OUR_KERNEL, page_size) + \
        align(ramdisk_size, page_size) + align(second_size, page_size) + align(dtb_size, page_size)
    print("换成我们的内核  : %d bytes (%.1f MiB)  %s" % (
        new_total, new_total / 1048576, "OK" if new_total <= PART else "!! 会超分区 !!"))
print("\ncmdline         : %s" % cmdline[:200])
print("extra_cmdline   : %s" % extra[:200])
