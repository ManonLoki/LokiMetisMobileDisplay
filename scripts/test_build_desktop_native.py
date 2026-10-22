"""桌面构建边界测试；无需 Rust、JDK、C 编译器或第三方 Python 依赖。"""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("build_desktop_native", Path(__file__).with_name("build_desktop_native.py"))
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)


class DesktopNativeBuildTests(unittest.TestCase):
    def test_cargo_requires_existing_lock_and_overrides_external_target(self):
        manifest = Path("external workspace/loki_metris_mobile_bridge/Cargo.toml")
        command = native.cargo_command("cargo", manifest, "aarch64-apple-darwin", "release")
        self.assertIn("--locked", command)
        self.assertIn("--lib", command)
        self.assertIn("--release", command)
        self.assertEqual(command[command.index("--manifest-path") + 1], manifest)
        self.assertEqual(command[command.index("--target") + 1], "aarch64-apple-darwin")
        self.assertNotIn("--release", native.cargo_command("cargo", manifest, "x86_64-unknown-linux-gnu", "debug"))

    def test_jdk_must_have_both_common_and_host_jni_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            java = Path(directory).resolve()
            (java / "include").mkdir()
            (java / "include" / "jni.h").write_text("", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "JNI"):
                native.validate_jdk(java, "linux")
            (java / "include" / "linux").mkdir()
            (java / "include" / "linux" / "jni_md.h").write_text("", encoding="utf-8")
            self.assertEqual(native.validate_jdk(java, "linux"), [java / "include", java / "include" / "linux"])

    def test_mac_jni_has_relative_install_name_and_private_rust_symbols(self):
        output = Path("output with spaces/libloki_metris_jni.dylib")
        archive = Path("isolated rust/libloki_metris_mobile_bridge.a")
        command = native.jni_command("Darwin", "aarch64-apple-darwin", "clang", Path("jni.c"),
                                     [Path("jdk include")], archive, output, ["Java_native_create"], Path("macOS SDK"))
        self.assertIn(archive, command)
        self.assertIn("-Wl,-install_name,@rpath/libloki_metris_jni.dylib", command)
        self.assertIn("-Wl,-rpath,@loader_path", command)
        self.assertIn("-Wl,-exported_symbol,_Java_native_create", command)
        self.assertEqual(command[command.index("-isysroot") + 1], Path("macOS SDK"))

    def test_linux_rejects_undefined_references_and_hides_rust_exports(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "libloki_metris_jni.so"
            command = native.jni_command("Linux", "x86_64-unknown-linux-gnu", "cc", Path("jni.c"), [],
                                         Path("rust.a"), output, ["Java_native_create"])
            self.assertIn("-Wl,--no-undefined", command)
            self.assertIn("-Wl,-rpath,$ORIGIN", command)
            exports = (output.parent / "jni-exports.map").read_text(encoding="utf-8")
            self.assertIn("global: Java_native_create;", exports)
            self.assertIn("local: *;", exports)

    def test_windows_msvc_uses_import_library_and_keeps_object_in_staging(self):
        output = Path("staging dir/loki_metris_jni.dll")
        import_library = Path("rust output/loki_metris_mobile_bridge.dll.lib")
        command = native.jni_command("Windows", "x86_64-pc-windows-msvc", "cl", Path("jni.c"),
                                     [Path("JDK Home/include")], import_library, output, [])
        self.assertIn(import_library, command)
        self.assertIn("/Fo" + str(output.with_suffix(".obj")), command)
        self.assertIn("/OUT:" + str(output), command)
        self.assertIn("/IJDK Home/include", command)

    def test_unsupported_hosts_and_missing_tools_fail_without_installation(self):
        with self.assertRaisesRegex(RuntimeError, "不支持宿主系统"):
            native.library_names("FreeBSD")
        with patch.object(native.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "不会安装工具"):
                native.require_tool("cargo", "Rust Cargo")


if __name__ == "__main__":
    unittest.main()
