#!/usr/bin/python3
"""Bound one backup invocation and always terminate its owned process group.

限定一次备份运行的时间预算，并保证超时后清理它拥有的整个进程组。
预算可经 GIT_BACKUP_BUDGET（秒）覆盖，默认 900。
"""
import os
import signal
import subprocess
import sys

RUN_SECONDS = int(os.environ.get("GIT_BACKUP_BUDGET", "900"))
CLEANUP_SECONDS = 10


def interrupt(signum, frame):
    raise InterruptedError("backup supervisor interrupted")


def main():
    process = subprocess.Popen(["/bin/bash", sys.argv[1], "--bounded-run"], start_new_session=True)
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        return process.wait(timeout=RUN_SECONDS)
    except (subprocess.TimeoutExpired, InterruptedError):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=CLEANUP_SECONDS)
        except subprocess.TimeoutExpired:
            pass
        # The shell may exit before a stubborn child. Always clean the owned group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
