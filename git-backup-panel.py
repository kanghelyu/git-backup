#!/usr/bin/python3
"""Git 一键备份 — 控制面板 / One-Click Git Backup — control panel.

一个简单的 GTK4 图形界面，用来查看备份状态、手动跑一次、开关自动调度。
所有路径与单元名来自 ~/.local/share/git-backup/config.json（不存在时使用默认值）。

后台机制（不在此界面内实现的）：
  - 执行脚本   ~/.local/share/git-backup/git-backup-run.sh
  - systemd    ~/.config/systemd/user/git-backup.{service,timer}
  - 调度       按定时器配置（默认每 5 小时一次），退出应用也继续跑
"""

import json
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk  # noqa: E402

BASE = os.environ.get("GIT_BACKUP_BASE",
                      os.path.expanduser("~/.local/share/git-backup"))
LOG = os.path.join(BASE, "scheduled-run.log")
RECEIPT = os.path.join(BASE, "LAST-RUN.md")
RUN_SCRIPT = os.path.join(BASE, "git-backup-run.sh")
RUN_PANEL = os.path.abspath(__file__)

TIMER = "git-backup.timer"
SERVICE = "git-backup.service"

# ------------------------------------------------------------------ 双语 UI
_LANG_PATH = os.environ.get("GIT_BACKUP_LANG",
                            os.path.join(BASE, "lang"))
_LANG = "zh"
try:
    _raw = open(_LANG_PATH, encoding="utf-8").read().strip()
    _LANG = _raw if _raw in ("zh", "en") else "zh"
except OSError:
    pass


def T(s: str) -> str:
    return _EN.get(s, s) if _LANG == "en" else s


def set_lang(lang: str) -> None:
    global _LANG
    _LANG = lang if lang in ("zh", "en") else "zh"
    try:
        with open(_LANG_PATH, "w", encoding="utf-8") as fh:
            fh.write(_LANG)
    except OSError:
        pass


_EN = {
    "Git 备份控制面板": "Git Backup Panel",
    "Git 备份": "Git Backup",
    "已开启": "ON", "已关闭": "OFF",
    "● 自动备份：已开启": "● Auto backup: ON",
    "○ 自动备份：已关闭": "○ Auto backup: OFF",
    "关闭自动备份": "Disable auto backup",
    "开启自动备份": "Enable auto backup",
    "立即备份一次": "Back up now",
    "刷新状态": "Refresh",
    "最近一次运行结果": "Last run receipt",
    "运行日志（末尾）": "Log (tail)",
    "下次运行": "Next run",
    "开机自启": "Enabled at boot",
    "后台常驻(linger)": "Linger",
    "当前是否正在跑": "Running now",
    "是": "yes", "否": "no",
    "(暂无)": "(none yet)", "(空)": "(empty)",
    "找不到执行脚本": "run script not found",
    "错误": "error",
}



def load_config() -> dict:
    try:
        with open(os.path.join(BASE, "config.json"), encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def sc(*args: str) -> str:
    """Run a systemctl --user command and return stdout (never raises)."""
    try:
        r = subprocess.run(
            ["systemctl", "--user", *args],
            capture_output=True, text=True, timeout=20,
        )
        return (r.stdout or "").strip()
    except Exception as exc:  # noqa: BLE001
        return f"(错误: {exc})"


def state() -> dict:
    return {
        "active": sc("is-active", TIMER),
        "enabled": sc("is-enabled", TIMER),
        "running": sc("is-active", SERVICE),
        "next": next_trigger(),
        "linger": linger_state(),
    }


def next_trigger() -> str:
    out = subprocess.run(
        ["systemctl", "--user", "list-timers", TIMER, "--no-pager"],
        capture_output=True, text=True, timeout=20,
    ).stdout
    lines = [l for l in out.splitlines() if l.strip()]
    if len(lines) >= 2:
        parts = lines[1].split()
        if parts and parts[0] != "-":
            return " ".join(parts[:3])
    return "—"


def linger_state() -> str:
    try:
        out = subprocess.run(
            ["loginctl", "show-user", os.environ.get("USER", ""), "-p", "Linger"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        return out.split("=")[-1] if "=" in out else "?"
    except Exception:  # noqa: BLE001
        return "?"


def read_tail(path: str, n: int = 12) -> str:
    if not os.path.exists(path):
        return T("(暂无)")
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return "".join(fh.readlines()[-n:]).strip() or T("(空)")
    except Exception as exc:  # noqa: BLE001
        return f"({T("错误")}: {exc})"


class Panel(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title=T("Git 备份控制面板"))
        self.set_default_size(620, 560)

        hb = Gtk.HeaderBar()
        lang_btn = Gtk.Button(label="EN / 中文" if _LANG == "zh" else "中文 / EN")
        lang_btn.add_css_class("flat")
        lang_btn.connect("clicked", self.on_toggle_lang)
        hb.pack_end(lang_btn)
        self.set_titlebar(hb)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        outer.set_margin_top(18)
        outer.set_margin_bottom(18)
        outer.set_margin_start(18)
        outer.set_margin_end(18)
        self.set_child(outer)

        cfg = load_config()
        title = Gtk.Label()
        repo = cfg.get("repo_slug") or "(未配置)"
        title.set_markup(f"<b><big>{T('Git 备份')}</big></b>　<span size='small' "
                         f"alpha='60%'>{repo} · {cfg.get('branch', 'main')}</span>")
        title.set_xalign(0)
        outer.append(title)

        self.status_label = Gtk.Label()
        self.status_label.set_xalign(0)
        self.status_label.add_css_class("dim-label")
        outer.append(self.status_label)

        sep = Gtk.Separator()
        outer.append(sep)

        # --- 按钮区 ---
        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)

        self.btn_toggle = Gtk.Button()
        self.btn_toggle.connect("clicked", self.on_toggle)
        btns.append(self.btn_toggle)

        btn_run = Gtk.Button(label=T("立即备份一次"))
        btn_run.connect("clicked", self.on_run_now)
        btns.append(btn_run)

        btn_refresh = Gtk.Button(label=T("刷新状态"))
        btn_refresh.connect("clicked", lambda *_: self.refresh())
        btns.append(btn_refresh)

        outer.append(btns)

        # --- 最近一次结果 ---
        outer.append(self.section_label(T("最近一次运行结果")))
        self.receipt_view = Gtk.TextView()
        self.receipt_view.set_editable(False)
        self.receipt_view.set_monospace(True)
        self.receipt_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        outer.append(self.scrolled(self.receipt_view, 190))

        # --- 日志尾部 ---
        outer.append(self.section_label(T("运行日志（末尾）")))
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_monospace(True)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        outer.append(self.scrolled(self.log_view, 150))

        self.refresh()

    @staticmethod
    def section_label(text: str) -> Gtk.Label:
        lbl = Gtk.Label()
        lbl.set_markup(f"<b>{text}</b>")
        lbl.set_xalign(0)
        return lbl

    @staticmethod
    def scrolled(widget: Gtk.Widget, height: int) -> Gtk.ScrolledWindow:
        sw = Gtk.ScrolledWindow()
        sw.set_min_content_height(height)
        sw.set_child(widget)
        sw.add_css_class("frame")
        return sw

    @staticmethod
    def set_text(view: Gtk.TextView, text: str) -> None:
        view.get_buffer().set_text(text)

    def refresh(self) -> None:
        st = state()

        if st["active"] == "active":
            status = T("● 自动备份：已开启")
        else:
            status = T("○ 自动备份：已关闭")

        self.btn_toggle.set_label(
            T("关闭自动备份") if st["active"] == "active" else T("开启自动备份")
        )

        yesno = lambda v: T("是") if v == "active" else T("否")
        self.status_label.set_markup(
            f"{status}\n"
            f"{T('下次运行')}：{st['next']}\n"
            f"{T('开机自启')}：{st['enabled']}　{T('后台常驻(linger)')}：{st['linger']}\n"
            f"{T('当前是否正在跑')}：{yesno(st['running'])}"
        )

        self.set_text(self.receipt_view, read_tail(RECEIPT, 14))
        self.set_text(self.log_view, read_tail(LOG, 12))

    def on_toggle_lang(self, _btn) -> None:
        set_lang("en" if _LANG == "zh" else "zh")
        self.get_root().close()          # 重启面板以应用语言（状态无副作用）
        subprocess.Popen([sys.executable, RUN_PANEL])

    def on_toggle(self, _btn) -> None:
        st = state()
        if st["active"] == "active":
            sc("stop", TIMER)
            sc("disable", TIMER)
        else:
            sc("enable", TIMER)
            sc("start", TIMER)
        self.refresh()

    def _watch(self, ticks: int = 0) -> bool:
        """备份期间每 3 秒刷新一次，跑到结束（或 40 次/2 分钟）就停。"""
        self.refresh()
        if sc("is-active", SERVICE) == "active" and ticks < 40:
            GLib.timeout_add_seconds(3, self._watch, ticks + 1)
            return False
        return False

    def on_run_now(self, _btn) -> None:
        # oneshot service；用 --no-block 让窗口立刻返回，不卡界面。
        subprocess.Popen(["systemctl", "--user", "start", "--no-block", SERVICE])
        self.refresh()
        GLib.timeout_add_seconds(3, self._watch, 0)


class PanelApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="org.kanghelyu.git-backup")

    def do_activate(self):
        win = self.props.active_window
        if not win:
            win = Panel(self)
        win.present()


def main() -> int:
    if not os.path.exists(RUN_SCRIPT):
        print(f"{T('找不到执行脚本')}：{RUN_SCRIPT}", file=sys.stderr)
        return 1
    return PanelApp().run([])


if __name__ == "__main__":
    sys.exit(main())
