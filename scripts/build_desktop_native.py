#!/usr/bin/env python3
"""构建当前宿主的 Rust 配对桥和 JVM JNI 包装，不安装工具或改写外部锁文件。

macOS 需要 Xcode Command Line Tools；Linux 需要 C 编译器及 libc 开发文件；
Windows MSVC 需要在 Visual Studio Native Tools 环境运行，GNU 目标需要 MinGW GCC。
所有平台均需已安装、架构相符的 Rust/Cargo 和带 JNI 头文件的 JDK。
Cargo 仅下载外部工作区及其 Cargo.lock 已声明的依赖，产物隔离在本项目 build 中。
"""

import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_NAME = "loki_metris_mobile_bridge"
JNI_NAME = "loki_metris_jni"


def run(command, *, env=None, cwd=None, capture=False):
    """以参数数组启动工具；路径可含空格，且不经过 shell。"""
    result = subprocess.run([str(value) for value in command], check=True, env=env, cwd=cwd,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else None


def require_tool(name, purpose):
    executable = shutil.which(name)
    if not executable:
        raise RuntimeError(f"缺少 {name}（{purpose}）；请先安装并配置开发环境，本脚本不会安装工具")
    return executable


def library_names(system):
    if system == "Darwin":
        return f"lib{BRIDGE_NAME}.dylib", f"lib{JNI_NAME}.dylib", f"lib{BRIDGE_NAME}.a", "darwin"
    if system == "Linux":
        return f"lib{BRIDGE_NAME}.so", f"lib{JNI_NAME}.so", f"lib{BRIDGE_NAME}.a", "linux"
    if system == "Windows":
        return f"{BRIDGE_NAME}.dll", f"{JNI_NAME}.dll", None, "win32"
    raise RuntimeError(f"不支持宿主系统 {system}；支持 macOS、Linux 与 Windows")


def cargo_command(cargo, manifest, host, configuration):
    # 显式宿主 target 避免外部 .cargo/config 或 CARGO_BUILD_TARGET 意外生成另一平台的库。
    command = [cargo, "build", "--manifest-path", manifest, "--lib", "--locked", "--target", host]
    if configuration == "release":
        command.append("--release")
    return command


def validate_jdk(java_home, platform_include):
    java_home = java_home.expanduser().resolve(strict=True)
    includes = [java_home / "include", java_home / "include" / platform_include]
    if not (includes[0] / "jni.h").is_file() or not (includes[1] / "jni_md.h").is_file():
        raise RuntimeError(f"--java-home 必须是当前平台完整 JDK 的 Home，缺少 JNI 头文件：{java_home}")
    return includes


def compiler_tools(system, host):
    if system == "Darwin":
        xcrun = require_tool("xcrun", "Xcode Command Line Tools")
        install_name_tool = require_tool("install_name_tool", "可搬移的 macOS 动态库安装名")
        compiler = run([xcrun, "--find", "clang"], capture=True).strip()
        if not Path(compiler).is_file():
            raise RuntimeError("Xcode 未提供 clang；请先配置 xcode-select 和 Command Line Tools")
        return compiler, install_name_tool
    if system == "Linux":
        return require_tool(os.environ.get("CC", "cc"), "Linux C 编译器与 libc 开发文件"), None
    if "-msvc" in host:
        return require_tool("cl", "Visual Studio Native Tools，需配置 INCLUDE/LIB"), None
    if "-gnu" in host:
        return require_tool(os.environ.get("CC", "gcc"), "与 Rust GNU 宿主架构相符的 MinGW GCC"), None
    raise RuntimeError(f"不支持 Windows Rust 宿主 {host}；使用 MSVC 或 GNU 工具链")


def jni_command(system, host, compiler, source, includes, rust_library, output, exported_symbols, sdk=None):
    """mac/Linux 静态链接 Rust 且只导出 JNI，防止另一个 bridge 动态库干扰内部符号。"""
    if system == "Windows" and "-msvc" in host:
        return [compiler, "/nologo", "/LD", "/O2", source,
                *[f"/I{path}" for path in includes], f"/Fo{output.with_suffix('.obj')}",
                "/link", rust_library, f"/OUT:{output}", f"/IMPLIB:{output.with_suffix('.lib')}"]
    command = [compiler, "-O2", "-shared", source, *[item for path in includes for item in ("-I", path)]]
    if system != "Windows":
        command.append("-fPIC")
    command += [rust_library, "-o", output]
    if system == "Darwin":
        if sdk is not None:
            command += ["-isysroot", sdk]
        # clang 默认链接 libSystem（已包含 libc/libm），避免重复传入其别名。
        command += ["-Wl,-install_name,@rpath/" + output.name, "-Wl,-rpath,@loader_path", "-lresolv"]
        for symbol in exported_symbols:
            command.append("-Wl,-exported_symbol,_" + symbol)
    elif system == "Linux":
        exports = output.parent / "jni-exports.map"
        exports.write_text("{\n  global: " + "; ".join(exported_symbols) + ";\n  local: *;\n};\n", encoding="utf-8")
        command += ["-Xlinker", "--version-script", "-Xlinker", exports,
                    "-Wl,--no-undefined", "-Wl,-z,origin", "-Wl,-rpath,$ORIGIN",
                    "-ldl", "-lpthread", "-lm", "-lrt", "-lutil", "-lc"]
    return command


def build(args):
    system = platform.system()
    bridge_name, jni_name, archive_name, platform_include = library_names(system)
    desktop = args.desktop_root.expanduser().resolve(strict=True)
    manifest = desktop / "loki_metris_mobile_bridge" / "Cargo.toml"
    header = desktop / "loki_metris_mobile_bridge" / "include" / "loki_metris_mobile.h"
    source = ROOT / "androidApp" / "src" / "main" / "c" / "loki_metris_jni.c"
    for required in (manifest, desktop / "Cargo.lock", header, source):
        if not required.is_file():
            raise RuntimeError(f"缺少构建输入：{required}")
    includes = validate_jdk(args.java_home, platform_include) + [header.parent]
    cargo = require_tool("cargo", "Rust Cargo")
    rustc = require_tool("rustc", "Rust 宿主工具链")
    version = run([rustc, "-vV"], capture=True)
    host = next((line.removeprefix("host: ") for line in version.splitlines() if line.startswith("host: ")), None)
    if not host:
        raise RuntimeError("rustc -vV 未返回宿主 target")
    compiler, install_name_tool = compiler_tools(system, host)
    sdk = None
    codesign = None
    if system == "Darwin":
        sdk = run([require_tool("xcrun", "macOS SDK"), "--sdk", "macosx", "--show-sdk-path"], capture=True).strip()
        if not (Path(sdk) / "usr" / "include" / "stdio.h").is_file():
            raise RuntimeError(f"Xcode macOS SDK 缺少 C 头文件：{sdk}")
        codesign = require_tool("codesign", "修改安装名后重新执行本地 ad-hoc 签名")
    out = args.out.expanduser().resolve()
    rust_out = ROOT / "build" / "desktop-native" / "rust"
    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(rust_out)
    print(f"desktop-native: Rust {host}, {args.configuration}, JDK {args.java_home}", flush=True)
    run(cargo_command(cargo, manifest, host, args.configuration), env=env, cwd=desktop)
    profile = rust_out / host / args.configuration
    bridge = profile / bridge_name
    if system == "Windows":
        # Windows 链接 Rust 生成的导入库；NativeLinkBridge 会先按绝对路径装载同目录 DLL。
        archive = profile / (f"{BRIDGE_NAME}.dll.lib" if "-msvc" in host else f"lib{BRIDGE_NAME}.dll.a")
    else:
        archive = profile / archive_name
    for artifact in (bridge, archive):
        if not artifact.is_file():
            raise RuntimeError(f"Rust 未生成预期的库：{artifact}")
    exports = re.findall(r"JNIEXPORT\s+\w+\s+JNICALL\s+(Java_\w+)\s*\(", source.read_text(encoding="utf-8"))
    if not exports:
        raise RuntimeError("JNI 源文件中没有可导出的 Java 入口")
    out.mkdir(parents=True, exist_ok=True)
    # 完整构建成功前保留上一次产物；不会把半成品 JNI 库交给运行中的 JVM。
    with tempfile.TemporaryDirectory(prefix=".desktop-native-", dir=out.parent) as staging:
        stage = Path(staging)
        staged_bridge = stage / bridge_name
        staged_jni = stage / jni_name
        shutil.copy2(bridge, staged_bridge)
        if system == "Darwin":
            run([install_name_tool, "-id", "@rpath/" + bridge_name, staged_bridge])
            # install_name_tool 改动会使 Rust 原有签名失效；本地签名不需要开发者证书。
            run([codesign, "--force", "--sign", "-", staged_bridge])
        run(jni_command(system, host, compiler, source, includes, archive, staged_jni, exports, sdk), cwd=stage)
        for artifact in (staged_bridge, staged_jni):
            os.replace(artifact, out / artifact.name)
    shutil.copy2(header, out / header.name)
    print(f"desktop-native: 已生成 {out / bridge_name} 和 {out / jni_name}", flush=True)


def main():
    # Windows 的重定向输出可能沿用 ANSI 代码页；构建日志统一 UTF-8，避免中文进度导致失败。
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desktop-root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--java-home", type=Path, required=True)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    try:
        build(parser.parse_args())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"desktop-native: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
