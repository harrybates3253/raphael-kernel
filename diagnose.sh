#!/usr/bin/env bash
# =============================================================================
# diagnose.sh — 把云端失败的「哪一步、什么错」扒出来（不需要 gh，只要 token）
#
#   GH_TOKEN=xxx ./diagnose.sh                                  # 默认 raphael-kernel，最近一次 run
#   GH_TOKEN=xxx ./diagnose.sh owner/repo                        # 指定仓库
#   GH_TOKEN=xxx ./diagnose.sh owner/repo 40088675073            # 指定 run id
#   GH_TOKEN=xxx ./diagnose.sh raphael-kernel 40088675073
# =============================================================================
set -euo pipefail
API="https://api.github.com"
FULL=""; RUN_ID=""
for a in "$@"; do
  case "$a" in
    -*) ;;
    *) if [[ "$a" =~ ^[0-9]{6,}$ ]]; then RUN_ID="$a"; else FULL="$a"; fi ;;
  esac
done
say() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M)" "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || { printf '粘贴 GitHub token: '; read -rs TOKEN; echo; }
[ -n "$TOKEN" ] || die "token 为空"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json")

LOGIN="$(curl -sS "${AUTH[@]}" "$API/user" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("login",""))')"
[ -n "$LOGIN" ] || die "token 无效"
[ -n "$FULL" ] || FULL="raphael-kernel"
case "$FULL" in */*) ;; *) FULL="$LOGIN/$FULL" ;; esac
say "仓库: $FULL"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$RUN_ID" ]; then
  curl -sS "${AUTH[@]}" "$API/repos/$FULL/actions/runs?per_page=5" -o "$TMP/runs.json"
  say "最近几次运行："
  python3 - "$TMP/runs.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
rs=d.get("workflow_runs",[])
if not rs: print("  (没有 run)")
for r in rs:
    print("  %-12s %-12s %-10s %s  %s" % (r["id"], r["status"], r.get("conclusion") or "-", r["created_at"], r["head_branch"]))
PY
  RUN_ID="$(python3 - "$TMP/runs.json" <<'PY'
import json,sys
rs=json.load(open(sys.argv[1])).get("workflow_runs",[])
print(rs[0]["id"] if rs else "")
PY
)"
fi
[ -n "$RUN_ID" ] || die "没有 run"
say "run $RUN_ID -> https://github.com/$FULL/actions/runs/$RUN_ID"

curl -sS "${AUTH[@]}" "$API/repos/$FULL/actions/runs/$RUN_ID/jobs" -o "$TMP/jobs.json"

echo
echo "===== 每个 step 的结论 ====="
python3 - "$TMP/jobs.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
jobs=d.get("jobs",[])
if not jobs:
    print("  (没有 job：run 可能在 set-up / 排队阶段就挂了)")
for j in jobs:
    print("JOB %s   status=%s  conclusion=%s" % (j["name"], j["status"], j.get("conclusion")))
    for s in j.get("steps", []):
        c = s.get("conclusion") or s.get("status")
        mark = "OK" if c == "success" else str(c)
        print("   [%-9s] %s" % (mark, s.get("name")))
PY

FAILED="$(python3 - "$TMP/jobs.json" <<'PY'
import json,sys
for j in json.load(open(sys.argv[1])).get("jobs", []):
    if j.get("conclusion") not in (None, "success"):
        print(j["id"])
PY
)"
[ -n "$FAILED" ] || { say "没有失败的 job（可能只是排队或被取消）"; exit 0; }

for JID in $FAILED; do
  say "拉 job $JID 日志"
  LOC="$(curl -sS -D - -o /dev/null "${AUTH[@]}" "$API/repos/$FULL/actions/jobs/$JID/logs" \
        | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')"
  if [ -z "$LOC" ]; then
    echo "  拿不到日志 URL（日志还在归档，等 1 分钟再跑本脚本；或去网页点开那个红 step）"
    continue
  fi
  OUT="/tmp/gh-job-$JID.log"
  curl -sSL "$LOC" -o "$OUT" || die "下载日志失败"
  echo "  日志: $OUT ($(wc -l <"$OUT") 行)"
  echo "  ---- error / 关键行 ----"
  grep -n -E "##\[error\]|^\[FAIL\]|Error [0-9]+|error:|fatal:|No such file|command not found|MISSING" "$OUT" | tail -30 || true
  echo "  ---- 尾部 40 行 ----"
  tail -40 "$OUT"
done
