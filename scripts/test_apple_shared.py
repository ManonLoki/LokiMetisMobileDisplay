#!/usr/bin/env python3
"""在 Apple Silicon macOS 生成 SharedLogic 并执行真实跨语言集成测试。

这不是 iOS/watchOS 模拟器测试入口；其余参数原样传给 swift test，例如 --filter。
与 Xcode 构建共用锁，避免测试框架和应用框架的 Gradle 生成步骤并发写入。
"""

import os
import platform
import subprocess
import sys

# 本地 helper 直接来自仓库，不在源码目录留下 __pycache__ 构建产物。
sys.dont_write_bytecode = True
from build_apple_shared import ROOT, run_gradle, shared_build_lock


def main():
    """先准备 macOS Debug 框架，再用明确的框架路径启动 SwiftPM 测试。"""
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("此测试入口需要 Apple Silicon macOS，与 macosArm64 目标对应。")
    with shared_build_lock():
        run_gradle(":sharedLogic:linkDebugFrameworkMacosArm64")
        environment = os.environ.copy()
        environment["LOKI_SHARED_LOGIC_FRAMEWORK_DIR"] = str(
            ROOT / "sharedLogic" / "build" / "bin" / "macosArm64" / "debugFramework"
        )
        subprocess.run(
            ["swift", "test", "--package-path", str(ROOT / "appleDisplay"), *sys.argv[1:]],
            cwd=ROOT, env=environment, check=True,
        )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
    except KeyboardInterrupt:
        raise SystemExit(130)
