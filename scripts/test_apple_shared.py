#!/usr/bin/env python3
"""先生成真实 macOS SharedLogic 框架，再运行 Apple Swift 测试；参数透传 swift test。"""

import os
import platform
import subprocess
import sys

# 本地 helper 直接来自仓库，不在源码目录留下 __pycache__ 构建产物。
sys.dont_write_bytecode = True
from build_apple_shared import ROOT, run_gradle, shared_build_lock


def main():
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
