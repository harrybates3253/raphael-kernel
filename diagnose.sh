#!/usr/bin/env bash
# =============================================================================
# diagnose.sh — 把云端失败的「哪一步、什么错」扒出来（不需要 gh，只要 token）
#
#   GH_TOKEN=xxx ./diagnose.sh                 # 仓库名默认 raphael-kernel，看最近一次 run
#   GH_TOKEN=xxx ./diagnose.sh raphael-kernel 1234567890    # 指定 run id
# =============================================================================
set -euo pipefail
API="https://api.github.com"
REPO_NAME="raphael-kernel"; RUN_ID=""
for a in "$@"; do
  case "$a" in
    -*) ;; 
    *) if [ -z "$RUN_ID" ] && [[ "$a" =~ ^[0-9]{6,}$ ]]; then RUN_ID="$a"; else REPO_NAME="$a"; fi ;;
  esac
done
say() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M)" "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }
jq_py() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null || true; }

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || { printf '粘贴 GitHub token: '; read -rs TOKEN; echo; }
[ -n "$TOKEN" ] || die "token 为空"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json")

LOGIN="$(curl -sS "${AUTH[@]}" "$API/user" | jq_py 'd["login"]')"
[ -n "$LOGIN" ] || die "token 无效"
say "仓库: $LOGIN/$REPO_NAME"

if [ -z "$RUN_ID" ]; then
  say "最近 5 次运行："
  curl -sS "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs?per_page=5" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("workflow_runs",[]):
    print(f"  {r[\"id\"]}  {r[\"status\"]:10s} {str(r[\"conclusion\"]):10s} {r[\"created_at\"]}  {r[\"head_branch\"]}")
' || die "拉 run 列表失败"
  RUN_ID="$(curl -sS "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs?per_page=1" | jq_py 'd["workflow_runs"][0]["id"]')"
fi
[ -n "$RUN_ID" ] || die "没有 run"
say "检查 run $RUN_ID : https://github.com/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID"

JOBS_JSON="$(curl -sS "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID/jobs")"
echo
echo "===== 每一步的结论 ====="
echo "$JOBS_JSON" | python3 -c '
import sys,json
d=json.load(sys.stdin)
jobs=d.get("jobs",[])
if not jobs: print("  (没有 job 记录：run 可能在排队/启动阶段就挂了)"); raise SystemExit
for j in jobs:
    print(f"JOB {j[\"name\"]}  status={j[\"status\"]}  conclusion={j[\"conclusion\"]}")
    for s in j.get("steps",[]):
        mark = "OK " if s.get("conclusion")=="success" else (str(s.get("conclusion")))
        print(f"   [{mark:9s}] {s.get(\"name\")}")
'
FAILED_IDS="$(echo "$JOBS_JSON" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for j in d.get("jobs",[]):
    if j.get("conclusion") not in (None,"success"):
        print(j["id"])
')"

[ -n "$FAILED_IDS" ] || { say "没有失败的 job（可能只是排队/取消）"; exit 0; }

for JID in $FAILED_IDS; do
  say "拉 job $JID 的日志"
  LOC="$(curl -sS -D - -o /dev/null "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/jobs/$JID/logs" \
        | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')"
  if [ -z "$LOC" ]; then echo "拿不到日志 URL（日志可能还没归档，等 1 分钟重跑本脚本）"; continue; fi
  OUT="/tmp/gh-job-$JID.log"
  curl -sSL "$LOC" -o "$OUT" || die "下载日志失败"
  echo "  日志: $OUT  ($(wc -l <"$OUT") 行)"
  echo "  ---- 错误行 ----"
  grep -n -E "##\[error\]|error:|Error|FAIL|fatal|not found|No such file" "$OUT" | tail -25 || true
  echo "  ---- 尾部 60 行 ----"
  tail -60 "$OUT"
done
