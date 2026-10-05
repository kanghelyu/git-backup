#!/bin/bash
# Git 一键备份 — 定时快照核心脚本
# One-Click Git Backup — the scheduled snapshot worker.
#
# 工作流：把 sources.json 里列出的本地目录 rsync 到一个专用 GitHub 仓库的
# 工作区，校验通过后提交并推送。所有参数来自 config.json / sources.json。
#
# Workflow: rsync the local directories listed in sources.json into a
# dedicated GitHub repository checkout, verify, commit and push. All
# parameters come from config.json / sources.json.
#
# 安全红线（继承自原始设计）：
#   - 永不 force push、永不 merge/reset 分叉历史
#   - 永不改仓库可见性；require_private=true 时仓库必须保持 PRIVATE
#   - 单次运行有硬性时间预算（超时优雅退出，已提交未推送的内容留给下次）
#   - flock 防并发；rsync --checksum 复核；mid-write 重试后仍不稳定则如实失败
#
# 退出码：0 = 成功/无变化/优雅跳过；非 0 = 硬失败。

set -uo pipefail

# 系统级 supervisor 拥有并清理整个备份进程组。
if [ "${1:-}" != "--bounded-run" ]; then
  exec /usr/bin/python3 "$(/usr/bin/dirname "$0")/backup-run-supervisor.py" "$0"
fi

BASE="${GIT_BACKUP_BASE:-$HOME/.local/share/git-backup}"
CONFIG="$BASE/config.json"
REPO="$BASE/repository"
LOCK="$BASE/upload.lock"
RUNLOG="$BASE/scheduled-run.log"
RECEIPT="$BASE/LAST-RUN.md"

export PATH=/usr/bin:/bin
mkdir -p "$BASE"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$RUNLOG"; }

# --- 读取配置（python 单次展开为 shell 可 eval 的赋值行） ---------------------
if [ ! -f "$CONFIG" ]; then
  log "FAIL: missing $CONFIG"
  echo "缺少配置文件：$CONFIG（参考 examples/config.json）" >&2
  exit 1
fi
EVAL_LINES=$(python3 - "$CONFIG" "$BASE" <<'PYCFG'
import json, sys
cfg = json.load(open(sys.argv[1]))
base = sys.argv[2]
def q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"
print("REPO_SLUG=" + q(cfg.get("repo_slug", "")))
print("BRANCH=" + q(cfg.get("branch", "main")))
print("REQUIRE_PRIVATE=" + q(str(bool(cfg.get("require_private", True)))))
print("DEADLINE_SECONDS=" + q(int(cfg.get("budget_seconds", 900))))
print("PUSH_RETRIES=" + q(int(cfg.get("push_retries", 2))))
print("SOURCES_JSON=" + q(cfg.get("sources_file") or base + "/sources.json"))
print("EXCLUDES=" + q(cfg.get("excludes_file") or ""))
PYCFG
) || { log "FAIL: cannot parse $CONFIG"; exit 1; }
eval "$EVAL_LINES"

[ -n "$REPO_SLUG" ] || { log "FAIL: config.repo_slug empty"; exit 1; }
[ -f "$SOURCES_JSON" ] || { log "FAIL: missing $SOURCES_JSON"; exit 1; }

START_EPOCH=$(date +%s)
elapsed() { echo $(( $(date +%s) - START_EPOCH )); }
remaining() { echo $(( DEADLINE_SECONDS - $(date +%s) + START_EPOCH )); }
over_budget() { [ "$(remaining)" -le 0 ]; }

write_receipt() {
  local outcome="$1" commit="$2" remote="$3" note="$4"
  python3 - "$RECEIPT" "$outcome" "$commit" "$remote" "$note" "$(elapsed)" "$REPO_SLUG" "$BRANCH" <<'PYRECEIPT'
import datetime, json, os, sys
path, outcome, commit, remote, note, elapsed, slug, branch = sys.argv[1:]
receipt = dict(at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    outcome=outcome, repository=slug, branch=branch, commit=commit,
    remote_commit=remote, elapsed_seconds=int(elapsed), note=note,
    mode="scheduled-script")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write("# Git backup receipt\n\n" + json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
os.replace(tmp, path)
PYRECEIPT
}

fail() {
  log "FAIL: $1"
  write_receipt "failed" "" "" "$1"
  exit 1
}

log "=== run start (pid $$) ==="

# --- 1. 全程独占非阻塞锁 ------------------------------------------------------
exec 9>"$LOCK" || fail "cannot open lock file"
if ! flock -n 9; then
  log "already running; another backup holds the lock. exit."
  exit 0
fi
log "lock acquired"
trap 'log "whole-run timeout or termination"; write_receipt "interrupted" "" "" "Whole-run timeout or external termination; snapshot not certified"; exit 124' TERM INT

git() {
  command /usr/bin/git -c credential.helper= -c 'credential.helper=!/usr/bin/gh auth git-credential' "$@"
}

# --- 2. 仓库身份与可见性 ------------------------------------------------------
VIS=$(gh repo view "$REPO_SLUG" --json visibility -q .visibility 2>/dev/null)
if [ "$REQUIRE_PRIVATE" = "True" ]; then
  [ "$VIS" = "PRIVATE" ] || fail "visibility is '$VIS', expected PRIVATE (never auto-change)"
fi
NAME=$(gh repo view "$REPO_SLUG" --json nameWithOwner -q .nameWithOwner 2>/dev/null)
[ "$NAME" = "$REPO_SLUG" ] || fail "repository identity mismatch: '$NAME'"
DEFBR=$(gh repo view "$REPO_SLUG" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
[ "$DEFBR" = "$BRANCH" ] || fail "default branch is '$DEFBR', expected '$BRANCH'"
log "repo verified: $NAME vis=$VIS default=$DEFBR"

# 导出令牌让 git push 在非交互会话里工作（无 keyring）。
GH_TOKEN_VALUE=$(gh auth token 2>/dev/null)
[ -n "$GH_TOKEN_VALUE" ] || fail "cannot obtain gh token"
export GH_TOKEN="$GH_TOKEN_VALUE"
export GIT_TERMINAL_PROMPT=0

# --- 3. 检出 -------------------------------------------------------------------
if [ ! -d "$REPO/.git" ]; then
  log "checkout absent; cloning"
  mkdir -p "$(dirname "$REPO")"
  git clone "https://github.com/$REPO_SLUG.git" "$REPO" >>"$RUNLOG" 2>&1 || fail "clone failed"
fi
cd "$REPO" || fail "cannot cd to checkout"
ORIGIN=$(git remote get-url origin 2>/dev/null)
case "$ORIGIN" in
  "https://github.com/$REPO_SLUG.git"|"https://github.com/$REPO_SLUG"|"git@github.com:$REPO_SLUG.git") : ;;
  *) fail "origin does not exactly match the authorized repository" ;;
esac
[ "$(git symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || fail "backup checkout is not on $BRANCH"

# 工作区只允许在受管目录（配置的 destinations）里出现改动 —— 其余脏路径一律拒绝。
python3 - "$REPO" "$SOURCES_JSON" <<'PYSTATUS' || fail "unrelated dirty paths present"
import json, os, subprocess, sys
repo, sources_file = sys.argv[1], sys.argv[2]
sources = json.load(open(sources_file)).get("sources", [])
managed = [os.path.normpath(s["destination"].strip("/")).encode()
           for s in sources if str(s.get("destination", "")).strip("/")]
raw = subprocess.check_output(["/usr/bin/git", "-C", repo,
                               "status", "--porcelain=v1", "-z", "--no-renames"])
for entry in raw.split(b"\0"):
    if not entry:
        continue
    path = entry[3:]
    if not any(path == m or path.startswith(m + b"/") for m in managed):
        raise SystemExit(1)
PYSTATUS

git fetch origin "$BRANCH" >>"$RUNLOG" 2>&1 || fail "fetch failed"
if git merge-base --is-ancestor "origin/$BRANCH" HEAD; then
  : # 保留已创建但未推送的备份提交。
elif git merge-base --is-ancestor HEAD "origin/$BRANCH"; then
  [ -z "$(git status --porcelain)" ] || fail "remote advanced while managed snapshots are dirty; preserve both for safe reconciliation"
  git merge --ff-only "origin/$BRANCH" >>"$RUNLOG" 2>&1 || fail "fast-forward failed"
else
  fail "local and remote history diverged; no merge/reset/force push attempted"
fi
AHEAD=$(git log "origin/$BRANCH..$BRANCH" --oneline 2>/dev/null | wc -l)
log "unpushed backup commits: $AHEAD"

# --- 4+5. 逐对复制并校验 -------------------------------------------------------
# 一次读入固定配对表（绝不重新发现路径）。
PAIRS=$(python3 - "$SOURCES_JSON" <<'PY'
import json, os, sys
p = json.load(open(sys.argv[1]))
for s in p['sources']:
    print(f"{os.path.realpath(str(s['source']).rstrip('/'))}|{s['destination']}")
PY
) || fail "cannot read $SOURCES_JSON"

MAX_COPY_RETRIES=2
RETRY_WAIT=45
PAIR_FAILED=0
DESTS=""

while IFS='|' read -r src dst; do
  [ -n "$src" ] || continue

  if [ ! -d "$src" ]; then
    log "source missing: $src"
    PAIR_FAILED=1
    continue
  fi

  DESTS="$DESTS $(printf '%q' "$(printf '%s' "$dst" | tr -d '\n')")"
  mkdir -p "$REPO/$dst"
  attempt=1
  ok=0
  while [ "$attempt" -le $((MAX_COPY_RETRIES + 1)) ]; do
    if over_budget; then
      log "time budget exhausted during copy of $dst; stopping gracefully"
      write_receipt "timeout-partial" "" "" "time ceiling reached; some snapshots not uploaded this run"
      exit 0
    fi

    # 复制。正在被写入的文件按此刻内容原样复制；随后的 --checksum
    # dry-run 复核能抓住复制中途发生变化的快照。
    rsync --archive --checksum --delete --delete-excluded \
          ${EXCLUDES:+--exclude-from="$EXCLUDES"} \
          --timeout=120 \
          "$src/" "$REPO/$dst" >>"$RUNLOG" 2>&1
    rc=$?

    # 用同样的参数做 dry-run、内容级校验。
    DIFF=$(rsync --archive --checksum --delete --delete-excluded \
            ${EXCLUDES:+--exclude-from="$EXCLUDES"} --dry-run --itemize-changes \
            --timeout=120 "$src/" "$REPO/$dst" 2>>"$RUNLOG")

    verify_rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 23 ] && [ "$rc" -ne 24 ]; then
      fail "rsync copy failed for $dst (exit $rc)"
    fi
    [ "$verify_rc" -eq 0 ] || fail "rsync checksum verification failed for $dst (exit $verify_rc)"
    if [ "$rc" -eq 0 ] && [ -z "$DIFF" ]; then
      ok=1
      break
    fi

    log "pair $dst attempt $attempt: rc=$rc, differences detected; retrying after ${RETRY_WAIT}s (mid-write input)"
    if [ "$(remaining)" -le $((RETRY_WAIT + 30)) ]; then
      log "not enough budget left to retry $dst; stopping gracefully"
      write_receipt "timeout-partial" "" "" "finite retries for mid-write input exhausted near the time ceiling"
      exit 0
    fi
    sleep "$RETRY_WAIT"
    attempt=$((attempt + 1))
  done

  if [ "$ok" -eq 1 ]; then
    log "pair ok: $dst"
  else
    log "pair STILL UNSTABLE after retries: $dst (inputs kept changing)"
    PAIR_FAILED=1
  fi
done <<< "$PAIRS"

if [ "$PAIR_FAILED" -eq 1 ]; then
  # 诚实的"输入不稳定"失败：某些快照无法在重试预算内证明忠实。
  fail "one or more snapshots could not be verified within the retry budget"
fi

# --- 7. 暂存、提交、仅在变化时推送 ---------------------------------------------
cd "$REPO" || fail "cannot cd to checkout"
# shellcheck disable=SC2086
git add -f -A -- $DESTS >>"$RUNLOG" 2>&1 || fail "staging failed"

STAGED=$(git diff --cached --name-only | wc -l)
PENDING=$(git log "origin/$BRANCH..$BRANCH" --oneline 2>/dev/null | wc -l)

if [ "$STAGED" -eq 0 ] && [ "$PENDING" -eq 0 ]; then
  log "no staged changes and nothing unpushed; unchanged"
  write_receipt "unchanged" "$(git rev-parse HEAD)" "$(git rev-parse origin/$BRANCH)" "no changes since last backup; commit and push skipped"
  echo "UNCHANGED: nothing to upload"
  exit 0
fi

COMMIT_MSG="backup: scheduled snapshot $(date -u '+%Y-%m-%d %H:%M UTC')"
if [ "$STAGED" -gt 0 ]; then
  python3 - "$REPO" $DESTS <<'PYSIZE' || fail "snapshot contains a regular file over the 100 MiB upload limit"
import os, sys
repo, scopes = sys.argv[1], sys.argv[2:]
for scope in scopes:
    root = os.path.join(repo, scope)
    for dirpath, dirs, files in os.walk(root):
        for name in files:
            p = os.path.join(dirpath, name)
            if not os.path.islink(p) and os.path.getsize(p) > 100 * 1024 * 1024:
                print("Oversized snapshot file: " + os.path.relpath(p, repo), file=sys.stderr)
                raise SystemExit(1)
PYSIZE
  git -c user.name="$(git config user.name || echo git-backup)" \
      -c user.email="$(git config user.email || echo git-backup@users.noreply.github.com)" \
      commit -q -m "$COMMIT_MSG" >>"$RUNLOG" 2>&1 || fail "commit failed"
fi

NEW_COMMIT=$(git rev-parse HEAD)
log "committed $NEW_COMMIT"

# 推送前重新确认可见性。
if [ "$REQUIRE_PRIVATE" = "True" ]; then
  VIS2=$(gh repo view "$REPO_SLUG" --json visibility -q .visibility 2>/dev/null)
  [ "$VIS2" = "PRIVATE" ] || fail "visibility changed to '$VIS2' before push; stopping"
fi

if over_budget; then
  log "ceiling reached before push; leaving commit local for the next run"
  write_receipt "committed-not-pushed" "$NEW_COMMIT" "" "time ceiling reached before push; commit preserved locally"
  exit 0
fi

push_ok=0
push_attempt=1
while [ "$push_attempt" -le "$PUSH_RETRIES" ]; do
  if over_budget; then
    write_receipt "committed-not-pushed" "$NEW_COMMIT" "" "time ceiling reached; pending commit retained"
    exit 0
  fi
  log "push attempt $push_attempt/$PUSH_RETRIES start; commit=$NEW_COMMIT"
  git push origin "$BRANCH" >>"$RUNLOG" 2>&1
  push_rc=$?
  log "push attempt $push_attempt/$PUSH_RETRIES finished; exit=$push_rc"
  if [ "$push_rc" -eq 0 ]; then
    push_ok=1
    break
  fi
  log "push failed; diagnostics recorded above; no force push"
  push_attempt=$((push_attempt + 1))
done
[ "$push_ok" -eq 1 ] || fail "all push attempts failed; task stopped immediately, pending commit retained; see scheduled-run.log"
log "pushed to origin/$BRANCH"

# --- 8. 远端哈希与可见性复核 ----------------------------------------------------
REMOTE_COMMIT=$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')
if [ "$REQUIRE_PRIVATE" = "True" ]; then
  VIS3=$(gh repo view "$REPO_SLUG" --json visibility -q .visibility 2>/dev/null)
  [ "$VIS3" = "PRIVATE" ] || fail "visibility changed to '$VIS3' after push"
fi

if [ "$NEW_COMMIT" != "$REMOTE_COMMIT" ]; then
  fail "remote hash $REMOTE_COMMIT != local $NEW_COMMIT"
fi

write_receipt "uploaded and remote verified" "$NEW_COMMIT" "$REMOTE_COMMIT" "all configured snapshots copied and checksum-verified; pushed normally"
log "=== run complete in $(elapsed)s : $NEW_COMMIT ==="
echo "OK: pushed $NEW_COMMIT in $(elapsed)s"
exit 0
