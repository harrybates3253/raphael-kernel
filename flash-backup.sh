#!/usr/bin/env bash
# =============================================================================
# flash-backup.sh — 刷机前备份 / 刷入 / 回滚（需要 adb + 手机已 root）
#
#   ./flash-backup.sh backup                # 备份 boot 分区到本机
#   ./flash-backup.sh flash  xxx.zip        # 推 zip 到手机并给出刷入步骤
#   ./flash-backup.sh rollback boot-xxx.img # 把备份 dd 回 boot 分区
#   ./flash-backup.sh info                  # 打印机型和当前内核版本
# =============================================================================
set -euo pipefail
BYPART="/dev/block/bootdevice/by-name/boot"
say() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
adbdev() { adb devices | awk 'NR>1 && $2=="device"{print $1; exit}'; }

case "${1:-}" in
  info)
    [ -n "$(adbdev)" ] || { echo "没连上设备（adb devices 里要有 device）"; exit 1; }
    adb shell 'getprop ro.product.device; getprop ro.product.model; getprop ro.build.version.release; \
                getprop ro.miui.ui.version.name; getprop ro.build.version.incremental; uname -r'
    ;;
  backup)
    [ -n "$(adbdev)" ] || { echo "没连上设备"; exit 1; }
    STAMP="$(date +%Y%m%d-%H%M)"
    OUT="boot-backup-raphael-$STAMP.img"
    say "dump $BYPART -> /sdcard/$OUT"
    adb shell "su -c 'dd if=$BYPART of=/sdcard/$OUT bs=4M'" || { echo "dd 失败：手机没 root 或分区名不对"; exit 1; }
    adb pull "/sdcard/$OUT" "./$OUT"
    adb shell "su -c 'rm -f /sdcard/$OUT'"
    sha256sum "./$OUT"
    say "备份完成: $PWD/$OUT （务必先拷到电脑/网盘再刷机）"
    ;;
  flash)
    ZIP="${2:-}"; [ -f "$ZIP" ] || { echo "用法: $0 flash <zip>"; exit 1; }
    [ -n "$(adbdev)" ] || { echo "没连上设备"; exit 1; }
    adb push "$ZIP" "/sdcard/$(basename "$ZIP")"
    cat <<EOF

已推到 /sdcard/$(basename "$ZIP")

刷入（任选一条，都不需要电脑）:
  A) KernelSU 管理器 -> 右下「安装」-> 选择文件 -> 选 /sdcard/$(basename "$ZIP")
     （推荐：KSU 自己会处理 ramdisk 补丁，保住 root）
  B) 进 TWRP -> Install -> 选该 zip -> 滑动刷入 -> 重启
  C) 没有 TWRP 也没有 KSU 管理器：先 dd 备份，再
     adb shell su -c 'dd if=/sdcard/Image of=$BYPART bs=4M'

刷完怎么确认成功:
  adb shell 'uname -r'                # 应出现 ...-droidspaces / 4.14.3xx
  adb shell 'cat /proc/version'
  打开 Droidspaces -> 设置 -> 要求 -> 检查要求   # 「必须/推荐」应全绿
  KernelSU 管理器首页应显示「工作中」
EOF
    ;;
  rollback)
    IMG="${2:-}"; [ -f "$IMG" ] || { echo "用法: $0 rollback <boot-backup.img>"; exit 1; }
    [ -n "$(adbdev)" ] || { echo "没连上设备"; exit 1; }
    say "回滚 $IMG -> $BYPART"
    adb push "$IMG" /sdcard/boot-rollback.img
    adb shell "su -c 'dd if=/sdcard/boot-rollback.img of=$BYPART bs=4M'"
    adb shell "su -c 'rm -f /sdcard/boot-rollback.img'"
    adb reboot
    ;;
  *)
    sed -n '2,12p' "$0"; exit 2 ;;
esac
