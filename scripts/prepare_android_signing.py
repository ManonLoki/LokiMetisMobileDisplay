#!/usr/bin/env python3
"""将 Android 固定签名保存在项目私有目录；默认保留本机已有开发证书。"""
import argparse
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, env=None):
    """捕获 keytool 输出并保留失败；密码通过专用环境变量传递，不拼进命令文本。"""
    return subprocess.run(command, env=env, check=True, capture_output=True, text=True).stdout


def main():
    """验证现有签名；缺失时默认迁移开发证书，只有 --new-key 才创建新证书。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--new-key", action="store_true", help="首次安装且无须沿用旧签名时生成新证书")
    args = parser.parse_args()
    keytool = shutil.which("keytool")
    if not keytool:
        raise SystemExit("未找到现有 JDK 的 keytool；未安装任何工具。")
    directory = ROOT / "signing"
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    store = directory / "lokimetris.keystore"
    properties = directory / "signing.properties"
    if store.exists() or properties.exists():
        if not (store.is_file() and properties.is_file()):
            raise SystemExit("签名文件不完整，请恢复原有文件；不会覆盖或另建密钥。")
        values = dict(line.split("=", 1) for line in properties.read_text().splitlines() if "=" in line)
        env = os.environ.copy()
        env["LOKI_SIGNING_STORE_PASSWORD"] = values["storePassword"]
        run([keytool, "-list", "-keystore", str(store), "-storepass:env", "LOKI_SIGNING_STORE_PASSWORD", "-alias", values["keyAlias"]], env)
        print(f"已验证项目签名：{store}\nkeytool：{keytool}")
        return
    previous = Path.home() / ".android/debug.keystore"
    if not args.new_key and not previous.is_file():
        raise SystemExit("没有找到原开发签名。请恢复旧签名；首次安装可显式使用 --new-key。")
    password = secrets.token_urlsafe(32)
    env = os.environ.copy()
    env["LOKI_SIGNING_STORE_PASSWORD"] = password
    env["LOKI_SIGNING_OLD_PASSWORD"] = "android"
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        destination = Path(temporary) / "lokimetris.keystore"
        if args.new_key:
            run([keytool, "-genkeypair", "-keystore", str(destination), "-storetype", "PKCS12",
                 "-storepass:env", "LOKI_SIGNING_STORE_PASSWORD", "-keypass:env", "LOKI_SIGNING_STORE_PASSWORD",
                 "-alias", "lokimetris", "-keyalg", "RSA", "-keysize", "3072", "-validity", "10000",
                 "-dname", "CN=LokiMetris, O=ManonLoki", "-noprompt"], env)
        else:
            run([keytool, "-importkeystore", "-srckeystore", str(previous), "-srcstorepass:env", "LOKI_SIGNING_OLD_PASSWORD",
                 "-srckeypass:env", "LOKI_SIGNING_OLD_PASSWORD", "-srcalias", "androiddebugkey",
                 "-destkeystore", str(destination), "-deststoretype", "PKCS12",
                 "-deststorepass:env", "LOKI_SIGNING_STORE_PASSWORD", "-destkeypass:env", "LOKI_SIGNING_STORE_PASSWORD",
                 "-destalias", "lokimetris", "-noprompt"], env)
        run([keytool, "-list", "-keystore", str(destination), "-storepass:env", "LOKI_SIGNING_STORE_PASSWORD", "-alias", "lokimetris"], env)
        destination.chmod(0o600)
        # 先完成并验证密钥，才发布密码文件；已存在任何文件均禁止覆盖。
        with properties.open("x") as output:
            os.chmod(properties, 0o600)
            output.write(f"keyAlias=lokimetris\nstorePassword={password}\nkeyPassword={password}\n")
        destination.rename(store)
    print(f"已保存并验证项目签名：{store}\n密码文件：{properties}\nkeytool：{keytool}")
    print("已生成新证书。" if args.new_key else "已保留原开发证书，可继续覆盖安装原签名的应用。")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError:
        raise SystemExit("keytool 操作失败，签名未完成；请检查原密钥和 JDK。")
