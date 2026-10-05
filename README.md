# Git 一键备份 · One-Click Git Backup **for Linux**

> **For Linux only · 仅支持 Linux。** 把任意多个本地目录定时快照到一个专用 GitHub 仓库：rsync 校验、私有仓库保护、永不强推，配一个 GTK4 小面板一键控制。

给你最怕丢的那几个目录（笔记、配置、项目）一个**全自动、可校验、有回执**的异地备份：systemd 用户定时器按节奏跑，每次运行把源目录 rsync 进一个专用备份仓库并推送到 GitHub——带内容级校验、防并发锁、硬性时间预算和"绝不强推"的安全设计。

```
本地目录 ──rsync --checksum──▶ 专用仓库工作区 ──校验通过──▶ commit ──▶ push ──▶ 远端哈希复核
     ▲                                                                        │
     └────────────────── GTK4 面板：状态 · 手动备份 · 调度开关 ◀──────────────────┘
```

## ✨ 功能特性

### 备份核心（`git-backup-run.sh`）
- **多目录快照表**：`sources.json` 里固定"源目录 → 仓库内位置"的配对表，绝不运行时重新发现路径
- **内容级校验**：`rsync --archive --checksum` 复制后，再用 `--dry-run --itemize-changes` 做逐字节复核，校验不过就重试
- **正在写入的文件不会坏账**：mid-write 文件复制后若校验不一致，等写方稳定后重试（有限次、不超总预算）；重试后仍不稳定则**如实失败**，绝不把没验证过的快照当成功
- **硬性时间预算**：整次运行限定秒数（默认 900s），到点优雅退出——已提交未推送的内容原地保留，下次运行接着推
- **flock 防并发**：上一轮没跑完时本轮直接退出，绝不并行写仓库
- **大小守卫**：快照里出现超过 100 MiB 的常规文件直接拒绝提交（GitHub 上限）

### 安全设计（红线，一条都不让步）
- **私有仓库保护**：`require_private: true` 时，运行前/推送前/推送后**三处**复核仓库可见性，一旦变成 public 立即中止且绝不自动改回
- **仓库身份三重验证**：slug、默认分支、origin URL 必须与配置完全一致
- **永不强推**：本地与远端历史分叉时直接失败，绝不 merge/reset/force push；远端领先时只做 fast-forward
- **工作区白名单**：检出仓库里只允许"配置的 destination 目录"有改动，出现任何无关脏路径立即拒绝提交
- **回执制度**：每次运行写一份机器可读的 `LAST-RUN.md`（结果 / 提交号 / 远端哈希 / 耗时 / 备注），成功必须以"远端哈希 == 本地哈希"收尾

### 控制面板（GTK4，`git-backup-panel.py`）
- 一屏看到：自动备份开关状态、下次触发时间、开机自启、后台常驻（linger）、是否正在跑
- **立即备份一次**：走 systemd oneshot，窗口不卡、运行中每 3 秒自动刷新
- **最近一次运行回执 + 日志尾部**直接在面板里看
- 开 / 关自动调度一键完成

### 🌐 中英双语
- 面板内置 **中 / EN 切换**（标题栏右上角），选择持久保存

### 📄 免责声明
本软件**按现状提供**，作者不对因使用或误用造成的任何数据丢失或其它问题承担责任：
备份仓库是快照产物，重要数据请遵循 3-2-1 原则（本工具只覆盖其中一环）。

### 调度（systemd user timer）
- 默认**每 5 小时**一次 + 开机 5 分钟后补跑一轮；`linger` 开启后不登录也照跑
- 完全离线可查：`journalctl --user -u git-backup`

## 📦 安装（Linux）

前提：`git`、`gh`（已 `gh auth login`）、`rsync`、`python3-gi`（GTK4）；备份目标仓库先在 GitHub 上建好（建议 **Private**）。

```bash
git clone https://github.com/kanghelyu/git-backup.git
cd git-backup

# 1. 装脚本到工作目录
mkdir -p ~/.local/share/git-backup
cp git-backup-run.sh backup-run-supervisor.py git-backup-panel.py \
   git-backup-enable.sh git-backup-disable.sh ~/.local/share/git-backup/
chmod +x ~/.local/share/git-backup/*.sh ~/.local/share/git-backup/*.py

# 2. 写配置（参考 examples/）
cp examples/config.json  ~/.local/share/git-backup/config.json   # 改 repo_slug
cp examples/sources.json ~/.local/share/git-backup/sources.json  # 改成你的目录
# 可选：cp examples/excludes.rsync ~/.local/share/git-backup/excludes.rsync

# 3. 装 systemd 用户单元并开启
mkdir -p ~/.config/systemd/user
cp systemd/git-backup.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
loginctl enable-linger "$USER"          # 不登录也照跑
systemctl --user enable --now git-backup.timer

# 4.（可选）桌面入口
cp desktop/git-backup.desktop ~/.local/share/applications/   # 把路径里的 YOUR_USER 改掉
```

装完先手动验证一次：

```bash
~/.local/share/git-backup/git-backup-run.sh     # 或直接开面板点"立即备份一次"
cat ~/.local/share/git-backup/LAST-RUN.md       # 回执
```

## ⚙️ 配置说明

**`config.json`**（工作目录下）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `repo_slug` | 必填 | 备份目标仓库，如 `you/my-backup` |
| `branch` | `main` | 推送分支（必须与仓库默认分支一致） |
| `require_private` | `true` | 仓库必须是 Private，否则拒绝运行（三重复核） |
| `budget_seconds` | `900` | 单次运行硬预算（秒） |
| `push_retries` | `2` | 推送重试次数 |
| `sources_file` / `excludes_file` | 内置路径 | 自定义快照表 / rsync 排除表位置 |

**`sources.json`**：`{"sources": [{"source": "本地目录", "destination": "仓库内子目录"}], ...}` —— destination 就是快照在备份仓库里落地的位置，也同时是"允许出现改动"的白名单。

## 🧯 故障排查

- `LAST-RUN.md` 的 `outcome` 一共有六种：`uploaded and remote verified` / `unchanged` / `committed-not-pushed` / `timeout-partial` / `failed` / `interrupted` —— 除了第一种，其余都说明"这轮没推完"，下轮定时器会自动接续
- 推送失败最常见原因是 `gh` 未登录或令牌过期：`gh auth status`
- `unrelated dirty paths present`：备份检出仓库里有白名单之外的改动，进 `~/.local/share/git-backup/repository` 用 `git status` 看一眼，处理掉再跑

## 📄 许可证

[PolyForm Noncommercial 1.0.0](./LICENSE) —— **严格不可商用**：个人学习、自用、修改、分享完全自由；任何以商业利益或金钱补偿为主要目的的使用都需要另行获得作者书面授权。**非传染性**：基于本项目的修改版没有强制开源义务，只需保留许可声明、满足非商用条件即可。

© 2026 Kanghe Lyu（kanghelyu）
