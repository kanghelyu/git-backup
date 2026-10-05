#!/bin/bash
# 开启 Git 一键备份的自动调度（按 config.json 的节奏，默认每 5 小时一次）。

set -uo pipefail

BASE="${GIT_BACKUP_BASE:-$HOME/.local/share/git-backup}"
RUNLOG="$BASE/scheduled-run.log"

export PATH="$HOME/.local/bin:$PATH"

echo "==============================================="
echo " 开启 Git 一键备份自动调度"
echo "==============================================="
echo

if systemctl --user is-enabled git-backup.timer >/dev/null 2>&1; then
  echo "状态：已经在运行，无需操作。"
  echo
  systemctl --user list-timers git-backup.timer --no-pager 2>/dev/null | sed -n '2p'
  echo
  read -r -p "按回车键关闭此窗口..." _
  exit 0
fi

echo "正在启用定时器..."
systemctl --user enable --now git-backup.timer 2>&1

echo
echo "-----------------------------------------------"
echo " 已开启（按定时器配置的节奏）"
echo "-----------------------------------------------"
echo
echo "定时器状态：$(systemctl --user is-active git-backup.timer 2>/dev/null)"
echo "自启状态：  $(systemctl --user is-enabled git-backup.timer 2>/dev/null)"
echo
echo "下次触发："
systemctl --user list-timers git-backup.timer --no-pager 2>/dev/null | sed -n '2p'
echo
printf '%s 手动开启调度\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RUNLOG"
echo
read -r -p "按回车键关闭此窗口..." _
