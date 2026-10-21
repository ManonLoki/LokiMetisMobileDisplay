#!/usr/bin/env python3
"""用现有Cargo/NDK/Apple SDK构建本地桥，不下载或安装工具与依赖。"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(command, *, env=None, cwd=None):
    """参数数组直接执行，保留真实失败，不经过shell拼接。"""
    subprocess.run([str(x) for x in command], check=True, env=env, cwd=cwd)


def ndk_path(explicit):
    """仅真实Android构建时定位已安装NDK，缺失时报错且不触发安装。"""
    value = explicit or os.environ.get("ANDROID_NDK_HOME")
    if value:
        return Path(value).expanduser().resolve(strict=True)
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    local = ROOT / "local.properties"
    if not sdk and local.is_file():
        for line in local.read_text().splitlines():
            if line.startswith("sdk.dir="):
                sdk = line.split("=", 1)[1].replace("\\:", ":").replace("\\\\", "\\")
    choices = list((Path(sdk) / "ndk").glob("*/source.properties")) if sdk else []
    if not choices:
        raise RuntimeError("未找到已安装NDK；请设置ANDROID_NDK_HOME或--ndk，本脚本不会安装工具")
    return sorted((x.parent for x in choices), key=lambda p: tuple(int(v) if v.isdigit() else 0 for v in p.name.split('.')))[-1]


def build(args):
    """SDK与架构单独决定Rust目标；Apple真机/模拟器的arm64绝不混用。"""
    desktop = args.desktop_root.resolve(strict=True)
    manifest = desktop / "loki_metris_mobile_bridge/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("desktop-root中缺少真实共享移动桥")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    rust_out = ROOT / "build/mobile-native/rust"
    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(rust_out)
    release = args.configuration.lower() == "release"
    if args.platform == "android":
        ndk = ndk_path(args.ndk)
        hosts = list((ndk / "toolchains/llvm/prebuilt").glob("*"))
        if len(hosts) != 1:
            raise RuntimeError("NDK宿主工具链不明确")
        for abi, target, clang_target in [("arm64-v8a", "aarch64-linux-android", "aarch64-linux-android"), ("x86_64", "x86_64-linux-android", "x86_64-linux-android")]:
            clang = hosts[0] / "bin" / f"{clang_target}31-clang"
            if not clang.is_file():
                raise RuntimeError("NDK中缺少API31 clang")
            target_env = env.copy()
            target_env[f"CARGO_TARGET_{target.upper().replace('-', '_')}_LINKER"] = str(clang)
            command = ["cargo", "build", "--manifest-path", manifest, "--lib", "--target", target]
            if release:
                command.append("--release")
            run(command, env=target_env, cwd=desktop)
            library = rust_out / target / ("release" if release else "debug") / "libloki_metris_mobile_bridge.so"
            destination = out / abi
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(library, destination / library.name)
            run([clang, "-shared", "-fPIC", "-O2", ROOT / "androidApp/src/main/c/loki_metris_jni.c", "-I", desktop / "loki_metris_mobile_bridge/include", "-L", library.parent, "-lloki_metris_mobile_bridge", "-o", destination / "libloki_metris_jni.so"])
    else:
        sdk = args.sdk or os.environ.get("PLATFORM_NAME")
        targets = {"iphoneos": "aarch64-apple-ios", "iphonesimulator": "aarch64-apple-ios-sim"}
        if sdk not in targets:
            raise RuntimeError("Apple SDK必须明确为iphoneos或iphonesimulator")
        target = targets[sdk]
        env["IPHONEOS_DEPLOYMENT_TARGET"] = "18.2"
        command = ["cargo", "build", "--manifest-path", manifest, "--lib", "--target", target]
        if release:
            command.append("--release")
        run(command, env=env, cwd=desktop)
        library = rust_out / target / ("release" if release else "debug") / "libloki_metris_mobile_bridge.a"
        shutil.copy2(library, out / library.name)
    shutil.copy2(desktop / "loki_metris_mobile_bridge/include/loki_metris_mobile.h", out / "loki_metris_mobile.h")


def main():
    """项目构建入口显式传递路径，不依赖调用者的当前目录。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desktop-root", type=Path, required=True)
    parser.add_argument("--platform", choices=["android", "ios"], required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--configuration", default="debug")
    parser.add_argument("--ndk")
    parser.add_argument("--sdk")
    try:
        build(parser.parse_args())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"mobile-native: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
