#!/usr/bin/env bash
# =============================================================================
# publish-to-github.sh — 在手机上把本 kit 推到 GitHub 并触发云端编译
#
#   ./publish-to-github.sh                 # 仓库名默认 raphael-kernel，公开仓库
#   ./publish-to-github.sh my-kernel       # 自定义仓库名
#   ./publish-to-github.sh raphael-kernel --no-watch   # 只推+触发，不在这儿等
#
# 前置：一次 `gh auth login`（用手机浏览器打开 https://github.com/login/device 输入 8 位码）
# =============================================================================
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="${1:-raphael-kernel}"; [ "${1:-}" = "--no-watch" ] && REPO_NAME="raphael-kernel"
WATCH=1; for a in "$@"; do [ "$a" = "--no-watch" ] && WATCH=0; done

say() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M)" "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

GH="${GH:-$(command -v gh 2>/dev/null || echo "$HOME/.local/bin/gh")}"
[ -x "$GH" ] || die "找不到 gh。装它: 从 https://github.com/cli/cli/releases 下 linux_arm64 包解压到 ~/.local/bin"

say "检查 GitHub 登录状态"
if ! "$GH" auth status >/dev/null 2>&1; then
  say "还没登录，走设备码流程（浏览器打开提示的网址，输入 8 位码）"
  "$GH" auth login --hostname github.com --git-protocol https --web || die "登录失败"
fi
OWNER="$("$GH" api user --jq .login)"
say "已登录: $OWNER"

cd "$KIT"
if [ ! -d .git ]; then
  say "初始化本地仓库"
  git init -q -b main
  git config user.name "${GIT_NAME:-$OWNER}"; git config user.email "${GIT_EMAIL:-$OWNER@users.noreply.github.com}"
  git add -A && git commit -q -m "raphael droidspaces+ksu kernel build kit"
else
  git add -A
  git diff --cached --quiet || git commit -q -m "update kit $(date -u +%FT%TZ)"
fi

if "$GH" repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  say "仓库已存在: $OWNER/$REPO_NAME，直接推"
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
  git push -u origin main
else
  say "创建仓库 $OWNER/$REPO_NAME (public) 并推送"
  "$GH" repo create "$REPO_NAME" --public --source=. --remote=origin --push
fi

say "触发云端编译"
"$GH" workflow run build.yml --ref main \
  -f repo="https://github.com/Laulan56/android_kernel_xiaomi_sm8150.git" \
  -f branch="android14" \
  -f defconfig="raphael_stock_defconfig" \
  -f ksu_tag="main" || die "触发失败（先看仓库 Actions 页是否已启用 workflow）"

sleep 8
RUN_ID="$("$GH" run list --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
say "运行 ID: $RUN_ID"
say "网页: https://github.com/$OWNER/$REPO_NAME/actions/runs/$RUN_ID"

if [ "$WATCH" = 1 ]; then
  say "盯着日志（Ctrl-C 可退出，云端照跑）"
  if "$GH" run watch "$RUN_ID" --interval 20; then
    say "编译成功，下载产物"
    "$GH" release download --pattern '*.zip' --dir "$KIT" --clobber || \
      "$GH" run download "$RUN_ID" --pattern '*.zip' --dir "$KIT" || true
  else
    say "失败，拉失败日志："
    "$GH" run view "$RUN_ID" --log-failed | tail -60 || true
    exit 1
  fi
else
  say "已触发，去 Actions 页看结果；完成后 Releases 里有 zip"
fi

ls -lh "$KIT"/*.zip 2>/dev/null || true
cat <<'EOF'

刷机（先备份 boot）:
  cd "$KIT"; ./flash-backup.sh backup
  ./flash-backup.sh flash ./raphael-4.14*.zip
EOF
