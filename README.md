# raphael-droidspaces-ksu — Redmi K20 Pro (raphael) / Mi 9 (cepheus) 内核编译套件

目标产物：**4.14.x 内核 + Droidspaces 容器支持 + KernelSU root**，刷进 HyperOS 1.0 / Android 14 的 raphael。
对应你提到的 Mi 9 `4.14.357-xturbo-droidspaces-ksu` 那套配方，只是换成 raphael 的树。

## 一分钟版

```bash
# 1) 体检（不编译，只验证补丁能打、config 能落地）
./build.sh --check

# 2) 真编译（WSL / Ubuntu 22.04+ / Debian 12，需要 ~15GiB 空闲）
./build.sh -j 12

# 3) 刷机前先备份 boot
./flash-backup.sh backup
# 4) KernelSU 管理器 -> 安装 -> 选生成的 zip；或 TWRP 刷
./flash-backup.sh flash ./raphael-4.14*.zip
```

没有电脑也行：把本目录 push 到自己 GitHub 仓库 → Actions → `Build raphael Droidspaces+KSU kernel` → Run workflow
→ 跑完在 Artifacts 里下 zip。见 `.github/workflows/build.yml`。

## 文件

| 文件 | 作用 |
|---|---|
| `build.sh` | 克隆源码 → 打补丁 → 集成 KernelSU → 合并 config → 闸门校验 → 编译 Image → 打 AnyKernel3 zip |
| `configs/droidspaces-raphael.config` | Droidspaces 必需 config + KSU 的 kprobe 三件套；注释里写了相对原厂 defconfig 的实测缺口 |
| `patches/02.fix_restore_cgroup_file_prefix_handling_.patch` | 4.14/4.19 必打（容器 cgroup 文件前缀） |
| `patches/01.fix_kernel_panic_in_xt_qtaguid.patch` | 3.18/4.4 才有意义；4.14.336 树里连 `xt_qtaguid.c` 都没有，脚本会自动跳过 |
| `verify.sh` | 只看不编：版本 / 补丁可打性 / fragment 相对 defconfig 改了什么 |
| `flash-backup.sh` | boot 备份、推包刷入、回滚 |
| `.github/workflows/build.yml` | 云端编译，手机/电脑都不需要 |

## 默认基线（实测）

- 源码：`Laulan56/android_kernel_xiaomi_sm8150@android14`，Makefile 实测 **4.14.336**
- defconfig：`raphael_stock_defconfig`（MIUI 原厂 config 导出的全量配置，5030 项，对 vendor 模块最友好）
- 这套 defconfig 实测 **KPROBES / SYSVIPC / PID_NS / DEVTMPFS / USER_NS / CGROUP_PIDS / MACVLAN 全是关的**
  → 直接编原厂内核能开机，但 Droidspaces 起不了容器、KSU 也挂不上 kprobe。fragment 就是补这些。

## 换树 / 换机型

```bash
./build.sh --repo https://github.com/Butterfingerss/Kernel_xiaomi_raphael.git \
           --branch 14-dsp --defconfig raphael_user_defconfig   # 4.14.353 备选
./build.sh --repo https://github.com/zclkkk/kernel_xiaomi_sm8150.git \
           --branch A14 --defconfig <看收件箱里的 defconfig 列表>
```

## 失败排查（按概率排序）

1. **clang 不兼容** → 换 `--llvm`、`--gcc`、`--clang-dir`；4.14 常见是汇编器报 `unknown directive`。
2. **配置闸门 MISSING** → 该树没有这个符号，或依赖没满足。看 `work/*/out/.config`，缺的多半是 `CONFIG_IPC_NS`（依赖 SYSVIPC）。
3. **刷完 wifi/相机没了** → 内核与 `/vendor/lib/modules` 的 vermagic 对不上。属于 4.14 换核必然风险，回滚备份 boot 即可。
4. **开机就重启** → kprobe 在这棵树上坏（极少见）；或用 `--ksu-tag` 换旧版本。
