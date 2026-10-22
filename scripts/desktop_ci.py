#!/usr/bin/env python3
"""Desktop CI 的工具校验与安装包收集；仅使用 Python 标准库，不发布版本。"""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DESKTOP_COMMIT = "0e326ceb745d7fa50119d61ab5a2ee59d868c9f6"


def output(command):
    result = subprocess.run([str(value) for value in command], check=True, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return result.stdout.strip()


def verify(args):
    source = args.desktop_root.resolve(strict=True)
    commit = output(["git", "-C", source, "rev-parse", "HEAD"])
    if commit != DESKTOP_COMMIT:
        raise RuntimeError("Rust source does not match the pinned CI commit")
    print(f"Rust source: {commit}", flush=True)
    for required in (source / "vendor", source / "loki_metris_pairing" / "Cargo.toml",
                     source / "loki_metris_mobile_bridge" / "Cargo.toml", source / "Cargo.lock"):
        if not required.exists():
            raise RuntimeError(f"Complete Rust workspace input is missing: {required}")
    java_home = Path(os.environ["JAVA_HOME"]).resolve(strict=True)
    for name, arguments in (("java", ["-version"]), ("javac", ["-version"]), ("jpackage", ["--version"])):
        executable = shutil.which(name)
        if not executable or Path(executable).resolve() != (java_home / "bin" / Path(executable).name).resolve():
            raise RuntimeError(f"{name} must use the configured Zulu JDK: {java_home}")
        version = output([executable, *arguments])
        print(f"{name}: {executable}\n{version}", flush=True)
        if not re.search(r'\b21(?:\.|\b)', version):
            raise RuntimeError(f"{name} is not version 21")
        if name == "java" and "zulu" not in version.lower():
            raise RuntimeError("The configured Java distribution is not Zulu")
    for name in ("rustc", "cargo"):
        executable = shutil.which(name)
        if not executable:
            raise RuntimeError(f"Missing Rust executable: {name}")
        actual = output(["rustup", "which", name])
        version = output([executable, "--version"])
        print(f"{name}: {executable}\nToolchain executable: {actual}\n{version}", flush=True)
        if name == "rustc" and not version.startswith("rustc 1.98.1 "):
            raise RuntimeError("Rust 1.98.1 is required for this CI build")


def collect(args):
    source = ROOT / "desktopApp" / "build" / "compose" / "binaries" / "main"
    packages = sorted(source.rglob(f"*.{args.format}"))
    if not packages:
        raise RuntimeError(f"No {args.format.upper()} installer was generated under {source}")
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    checksums = []
    names = set()
    for package in packages:
        if package.name in names:
            raise RuntimeError(f"Duplicate installer filename: {package.name}")
        names.add(package.name)
        if not package.is_file() or package.is_symlink():
            raise RuntimeError(f"Installer is not a regular file: {package}")
        target = destination / package.name
        shutil.copy2(package, target)
        digest = hashlib.sha256()
        with target.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        checksums.append(f"{digest.hexdigest()}  {target.name}\n")
        print(f"Collected: {target}", flush=True)
    (destination / "SHA256SUMS").write_bytes("".join(checksums).encode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("verify")
    check.add_argument("--desktop-root", type=Path, required=True)
    gather = commands.add_parser("collect")
    gather.add_argument("--format", choices=("msi", "deb"), required=True)
    gather.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        {"verify": verify, "collect": collect}[args.command](args)
    except (OSError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"desktop-ci: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
