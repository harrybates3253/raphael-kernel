#!/usr/bin/env python3
# =============================================================================
# repack-boot.py — 把新内核塞进已有的 boot.img（Android boot header v0）
#   保留原 ramdisk（因此 Magisk/KernelSU 的 ramdisk 补丁不会丢）
#   用法: repack-boot.py <base_boot.img> <new_kernel_blob> <out_boot.img>
# =============================================================================
import hashlib
import struct
import sys

base_path, kern_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
base = bytearray(open(base_path, "rb").read())
new_kernel = open(kern_path, "rb").read()

assert base[:8] == b"ANDROID!", "base 不是 Android boot image"
page = struct.unpack_from("<I", base, 36)[0]
hdr_ver = struct.unpack_from("<I", base, 40)[0]
assert hdr_ver == 0, "只支持 header v0（本机就是 v0）"

def align(n, p):
    return (n + p - 1) // p * p if n else 0

rd_size = struct.unpack_from("<I", base, 16)[0]
sec_size = struct.unpack_from("<I", base, 24)[0]

ramdisk = bytes(base[align(page, page) + align(struct.unpack_from("<I", base, 8)[0], page):
                     align(page, page) + align(struct.unpack_from("<I", base, 8)[0], page) + rd_size])
second = b""
if sec_size:
    off = align(page, page) + align(struct.unpack_from("<I", base, 8)[0], page) + align(rd_size, page)
    second = bytes(base[off:off + sec_size])

hdr = bytearray(base[:page])
struct.pack_into("<I", hdr, 8, len(new_kernel))

# 按 AOSP 规范重算 id: SHA1(kernel, kernel_size, ramdisk, ramdisk_size, second, second_size)
h = hashlib.sha1()
for blob in (new_kernel, struct.pack("<I", len(new_kernel)),
             ramdisk, struct.pack("<I", len(ramdisk)),
             second, struct.pack("<I", len(second))):
    h.update(blob)
hdr[576:576 + 20] = h.digest()   # id 字段在 offset 576

img = bytes(hdr) + b"\x00" * (align(page, page) - page)
img += new_kernel + b"\x00" * (align(len(new_kernel), page) - len(new_kernel))
img += ramdisk + b"\x00" * (align(len(ramdisk), page) - len(ramdisk))
if second:
    img += second + b"\x00" * (align(len(second), page) - len(second))

open(out_path, "wb").write(img)
print("base       : %s (kernel %d, ramdisk %d, page %d)" % (
    base_path, struct.unpack_from("<I", base, 8)[0], rd_size, page))
print("new kernel : %s (%d bytes, %.1f MiB)" % (kern_path, len(new_kernel), len(new_kernel) / 1048576))
print("output     : %s (%d bytes, %.1f MiB)" % (out_path, len(img), len(img) / 1048576))
print("sha1 id    : %s" % h.hexdigest())
