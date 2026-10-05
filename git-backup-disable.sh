#!/bin/bash
# 关闭 Git 一键备份的自动调度（数据与配置都保留，随时可重新开启）。

set -uo pipefail

BASE="${GIT_BACKUP_BASE:-$HOME/.local/share/git-backup}"
RUNLOG="$BASE/scheduled-run.log"

echo "==============================================="
echo " 关闭 Git 一键备份自动调度"
echo "==============================================="
echo

if ! systemctl --user is-enabled git-backup.timer >/dev/null 2>&1; then
  echo "状态：本来就没有开启。"
  echo
  read -r -p "按回车键关闭此窗口..." _
  exit 0
fi

echo "正在停用定时器..."
systemctl --user disable --now git-backup.timer 2>&1

echo
echo "-----------------------------------------------"
echo " 已关闭（配置与日志保留在 $BASE）"
echo "-----------------------------------------------"
echo
echo "定时器状态：$(systemctl --user is-active git-backup.timer 2>/dev/null)"
echo "自启状态：  $(systemctl --user is-enabled git-backup.timer 2>/dev/null)"
echo
printf '%s 手动关闭调度\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RUNLOG"
echo
read -r -p "按回车键关闭此窗口..." _
