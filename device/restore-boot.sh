#!/system/bin/sh
# 恢复原始 boot 分区（在 adb root shell 或 TWRP 终端里跑：sh /sdcard/restore-boot.sh）
B=/dev/block/bootdevice/by-name/boot
dd if=/sdcard/restore-full.bin   of=$B bs=4M
dd if=/sdcard/restore-footer.bin of=$B bs=1 seek=$((134217728-64)) conv=notrunc
sync
echo "restored. reboot now."
