#!/usr/bin/env python3
"""在 Apple 宿主上串行构建 SharedLogic，供多个 Xcode target 共用。"""

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def shared_build_lock():
    """避免 App、Widget、Watch 的并行脚本同时更新同一框架目录。"""
    lock_path = ROOT / ".gradle" / "apple-shared-build.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def run_gradle(task):
    """沿用当前 Xcode SDK、架构和构建配置，使用项目声明的 Gradle/Kotlin。"""
    subprocess.run([str(ROOT / "gradlew"), task, "--console=plain"], cwd=ROOT, check=True)


def main():
    if sys.platform != "darwin":
        raise SystemExit("Apple 框架必须在 macOS 上构建。")
    required = ("SDK_NAME", "ARCHS", "CONFIGURATION", "TARGET_BUILD_DIR", "FRAMEWORKS_FOLDER_PATH")
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SystemExit("请从 Xcode 构建阶段调用；缺少环境变量：" + ", ".join(missing))
    # 各 target 都校验自身 SDK/架构的产物；IDE 提前构建的另一个 target 不能替代它。
    with shared_build_lock():
        run_gradle(":sharedLogic:embedAndSignAppleFrameworkForXcode")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
    except KeyboardInterrupt:
        raise SystemExit(130)
