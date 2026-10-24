#!/usr/bin/env bash
# =============================================================================
# publish-to-github.sh — 手机上一键：建仓库 / 推代码 / 触发云端编译 / 等结果 / 下 zip
# 不需要装 gh，只用 git + curl + python3（容器里都有）。
#
# 用法:
#   ./publish-to-github.sh                      # 交互粘贴 token，仓库名 raphael-kernel
#   GH_TOKEN=xxx ./publish-to-github.sh my-kernel
#   ./publish-to-github.sh raphael-kernel --no-watch     # 只推+触发，不等
#
# Token 怎么弄（1 分钟，手机浏览器可完成）:
#   github.com/settings/tokens -> Generate new token (classic)
#   勾选:  repo  +  workflow        （workflow 不加就推不上 .github/workflows/）
#   有效期建议 7 天，用完删掉
# =============================================================================
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="https://api.github.com"
REPO_NAME="raphael-kernel"
WATCH=1
for a in "$@"; do
  case "$a" in
    --no-watch) WATCH=0 ;;
    -*) echo "未知参数 $a"; exit 2 ;;
    *) REPO_NAME="$a" ;;
  esac
done

say()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M)" "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

TOKEN="${GH_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  printf '粘贴 GitHub token（输入不回显）: '; read -rs TOKEN; echo
fi
[ -n "$TOKEN" ] || die "token 为空"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

say "校验 token"
LOGIN="$(curl -sS "${AUTH[@]}" "$API/user" | jget 'd["login"]')"
[ -n "$LOGIN" ] || die "token 无效（或没网）"
say "登录身份: $LOGIN"

say "建仓库 $LOGIN/$REPO_NAME（已存在就复用）"
CODE="$(curl -sS -o /tmp/gh_create.json -w '%{http_code}' -X POST "${AUTH[@]}" \
        "$API/user/repos" -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"auto_init\":false}")"
case "$CODE" in
  201) say "仓库已创建（public）" ;;
  422) say "仓库已存在，复用" ;;
  *)   die "建仓库失败 HTTP $CODE: $(cat /tmp/gh_create.json)" ;;
esac

cd "$KIT"
if [ ! -d .git ]; then
  say "初始化本地 git 仓库"
  git init -q -b main
  git config user.name "$LOGIN"; git config user.email "$LOGIN@users.noreply.github.com"
fi
git add -A
git diff --cached --quiet || git commit -q -m "update kit $(date -u +%FT%TZ)"
git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:$TOKEN@github.com/$LOGIN/$REPO_NAME.git"

say "推送代码"
git push -q -u origin main || die "推送失败（token 少了 repo 或 workflow 权限？）"
say "已推送: https://github.com/$LOGIN/$REPO_NAME"

say "触发云端编译"
CODE="$(curl -sS -o /tmp/gh_disp.json -w '%{http_code}' -X POST "${AUTH[@]}" \
  "$API/repos/$LOGIN/$REPO_NAME/actions/workflows/build.yml/dispatches" \
  -d '{"ref":"main","inputs":{"repo":"https://github.com/Laulan56/android_kernel_xiaomi_sm8150.git","branch":"android14","defconfig":"raphael_stock_defconfig","ksu_tag":"main","tag":""}}')"
case "$CODE" in
  204) say "已触发" ;;
  404) die "触发 404：仓库还没启用 Actions，或 workflow 文件没推上去（看 https://github.com/$LOGIN/$REPO_NAME/actions）" ;;
  *)   die "触发失败 HTTP $CODE: $(cat /tmp/gh_disp.json)" ;;
esac

sleep 10
RUN_ID="$(curl -sS "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/workflows/build.yml/runs?per_page=1" | jget 'd["workflow_runs"][0]["id"]')"
[ -n "$RUN_ID" ] || die "拿不到 run id"
say "运行页: https://github.com/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID"

[ "$WATCH" = 1 ] || { say "已触发，不再等待"; exit 0; }

say "等编译（约 25~40 分钟，Ctrl-C 退出云端照跑）"
LAST=""
for i in $(seq 1 180); do
  J="$(curl -sS "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID" || true)"
  ST="$(echo "$J" | jget 'd["status"]')"
  CO="$(echo "$J" | jget 'd["conclusion"] or ""')"
  if [ "$ST" != "$LAST" ]; then say "状态: $ST ${CO:-...}"; LAST="$ST"; fi
  case "$ST" in
    completed) break ;;
  esac
  sleep 20
done

if [ "$CO" != "success" ]; then
  say "结论: ${CO:-unknown}，开始定位失败步骤："
  GH_TOKEN="$TOKEN" "$KIT/diagnose.sh" "$REPO_NAME" "$RUN_ID" || true
  die "云端编译失败（上面是逐 step 结论 + 日志尾部）"
fi

say "编译成功，下载产物"
ART="$(curl -sS "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID/artifacts" | jget 'd["artifacts"][0]["archive_download_url"]')"
if [ -n "$ART" ]; then
  curl -sSL -H "Authorization: Bearer $TOKEN" "$ART" -o /tmp/kernel-artifacts.zip
  unzip -o -q /tmp/kernel-artifacts.zip -d "$KIT" && say "产物已解压到 $KIT"
else
  say "没有 artifact，去 Releases 页拿"
fi

ls -lh "$KIT"/*.zip 2>/dev/null || true
cat <<EOF

================ 下一步 ================
1) 备份 boot:
     cd "$KIT" && ./flash-backup.sh backup
2) 刷入（KernelSU 管理器 -> 安装 -> 选这个 zip；或 TWRP）:
     ./flash-backup.sh flash "$KIT"/raphael-4.14*.zip
3) 验证:
     adb shell uname -r          # 应出现 4.14.3xx
     Droidspaces App -> 设置 -> 要求 -> 检查要求
下载地址（手机直接点）:
     https://github.com/$LOGIN/$REPO_NAME/releases
=======================================
EOF
