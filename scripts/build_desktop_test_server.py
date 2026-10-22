#!/usr/bin/env python3
"""用已有外部协议 crate 构建隔离的真实 TCP 测试桌面，不修改外部源码或 Cargo.lock。

生成的 Cargo.toml、锁文件副本、PNG 和编译产物均位于本项目 build/desktop-test-server。
这里只构建测试可执行文件，不启动服务、不安装工具，也不进入正式安装包。
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
BINARY = "desktop_link_fixture"


def run(command, *, cwd=None, env=None, capture=False, quiet=False):
    return subprocess.run([str(value) for value in command], check=True, cwd=cwd, env=env, text=True,
                          stdout=subprocess.PIPE if capture else (subprocess.DEVNULL if quiet else None)).stdout


def write_if_changed(path, content):
    if not path.is_file() or path.read_bytes() != content:
        path.write_bytes(content)


def test_png():
    """真实可解码的 2×2 RGBA PNG；仅使用 Python 标准库生成。"""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = bytes([0, 103, 232, 249, 255, 174, 140, 255, 255] * 2)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


def build(args):
    desktop = args.desktop_root.expanduser().resolve(strict=True)
    external_lock = desktop / "Cargo.lock"
    pairing = desktop / "loki_metris_pairing"
    source = ROOT / "desktopApp" / "src" / "desktopTest" / "rust" / "server.rs"
    for path in (external_lock, pairing / "Cargo.toml", source):
        if not path.is_file():
            raise RuntimeError(f"缺少测试构建输入：{path}")
    cargo, rustc = shutil.which("cargo"), shutil.which("rustc")
    if not cargo or not rustc:
        raise RuntimeError("需要已安装的 Rust/Cargo；测试脚本不会安装工具")
    host = next((line.removeprefix("host: ") for line in run([rustc, "-vV"], capture=True).splitlines()
                 if line.startswith("host: ")), None)
    if not host:
        raise RuntimeError("rustc 未返回宿主 target")
    # Cargo.lock 的 package 记录只需读取两个固定字符串字段，兼容系统 Python 3.9，
    # 不为这一处测试配置引入第三方 TOML 解析器或要求升级解释器。
    serde_json = None
    for record in external_lock.read_text(encoding="utf-8").split("[[package]]")[1:]:
        if re.search(r'^name\s*=\s*"serde_json"\s*$', record, re.MULTILINE):
            version = re.search(r'^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*$', record, re.MULTILINE)
            if version:
                serde_json = version.group(1)
                break
    if not serde_json:
        raise RuntimeError("外部 Cargo.lock 中缺少已声明的 serde_json")
    out = args.out.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    manifest = out / "Cargo.toml"
    text = f'''# Generated only for DesktopApp integration tests.
[package]
name = "{BINARY}"
version = "0.1.0"
edition = "2024"

[workspace]

[[bin]]
name = "{BINARY}"
path = {json.dumps(str(source))}

[dependencies]
loki_metris_pairing = {{ path = {json.dumps(str(pairing))} }}
serde_json = "={serde_json}"
'''
    write_if_changed(manifest, text.encode("utf-8"))
    # 只在隔离副本中加入测试根包；实际协议依赖优先沿用外部工作区已锁定版本。
    shutil.copy2(external_lock, out / "Cargo.lock")
    png = out / "fixture.png"
    write_if_changed(png, test_png())
    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(out / "target")
    env["LOKI_DESKTOP_TEST_PNG"] = str(png)
    run([cargo, "metadata", "--manifest-path", manifest, "--format-version", "1"], cwd=out, env=env, quiet=True)
    command = [cargo, "build", "--manifest-path", manifest, "--locked", "--bin", BINARY, "--target", host]
    if args.configuration == "release":
        command.append("--release")
    run(command, cwd=out, env=env)
    executable = out / "target" / host / args.configuration / (BINARY + (".exe" if sys.platform == "win32" else ""))
    if not executable.is_file():
        raise RuntimeError(f"未生成测试服务：{executable}")
    stable = out / executable.name
    with tempfile.TemporaryDirectory(prefix=".fixture-", dir=out) as staging:
        staged = Path(staging) / executable.name
        shutil.copy2(executable, staged)
        os.replace(staged, stable)
    print(json.dumps({"executable": str(stable)}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desktop-root", required=True, type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "build" / "desktop-test-server")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    try:
        build(parser.parse_args())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"desktop-test-server: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
