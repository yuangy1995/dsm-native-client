#!/usr/bin/env python3
"""验证手动打包的身份字段，不访问真实钥匙串或开发者账号。"""

import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "apple/Apps/DsmMac/package.sh"


class MacOSSigningTests(unittest.TestCase):
    def test_packager_does_not_inject_removed_diagnostic_flags(self):
        source = PACKAGE.read_text()
        for marker in ["LANSTASH_CONNECTION_TRACE", "LANSTASH_DIAGNOSTIC_FILES_ONLY",
                       "LanStashConnectionTracingEnabled", "LanStashDiagnosticFilesOnly"]:
            self.assertNotIn(marker, source)

    def test_local_exception_is_separate_from_formal_signing(self):
        key = "com.apple.security.cs.disable-library-validation"
        local = ROOT / "apple/Apps/DsmMac/SupportingFiles/DsmMacLocalTest.entitlements"
        self.assertEqual(plistlib.loads(local.read_bytes()), {key: True})
        for target in ["DsmMac", "DsmFileProvider"]:
            formal = ROOT / f"apple/Apps/DsmMac/SupportingFiles/{target}.entitlements"
            self.assertNotIn(key, plistlib.loads(formal.read_bytes()))
        signing = PACKAGE.read_text().split('echo "==> 签名应用"\n', 1)[1]
        local_branch, rest = signing.split("\nelse\n", 1)
        formal_branch = rest.split("\nfi\n/usr/bin/codesign --verify", 1)[0]
        self.assertIn("sign_macos_local_test.sh", local_branch)
        self.assertNotIn("sign_macos_local_test.sh", formal_branch)
        self.assertNotIn("DsmMacLocalTest.entitlements", formal_branch)

    def test_formal_gate_rejects_local_exception_in_either_executable(self):
        source = (ROOT / "tools/release/verify_macos_distribution.sh").read_text()
        marker = '[[ "$APP_ENTITLEMENTS" != *"com.apple.security.cs.disable-library-validation"*'
        start = source.index(marker)
        guard = source[start:source.index("\nfor entitlement in", start)]
        script = 'set -euo pipefail\nfail() { exit 1; }\nAPP_ENTITLEMENTS="$1"\nEXTENSION_ENTITLEMENTS="$2"\n' + guard
        key = "com.apple.security.cs.disable-library-validation"
        for app, extension, expected in [("", "", 0), (key, "", 1), ("", key, 1)]:
            with self.subTest(app=bool(app), extension=bool(extension)):
                result = subprocess.run(["/bin/bash", "-c", script, "gate-test", app, extension], capture_output=True)
                self.assertEqual(result.returncode, expected)

    def test_local_signing_allows_actual_library_load_without_disabling_runtime(self):
        # 使用独立小程序和合成动态库，不启动真实 App、不读取登录资料。
        with tempfile.TemporaryDirectory(prefix="lanstash-signing-test-") as directory:
            root = Path(directory)
            app = root / "Probe.app"
            executable = app / "Contents/MacOS/Probe"
            library = app / "Contents/Frameworks/libProbe.dylib"
            executable.parent.mkdir(parents=True)
            library.parent.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "example.lanstash.signing-test",
                "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            }))
            library_source = root / "library.c"
            library_source.write_text("int probe_value(void) { return 7; }\n")
            subprocess.run(["xcrun", "clang", "-dynamiclib", str(library_source), "-o", str(library)], check=True, capture_output=True)
            probe_source = ROOT / "tools/release/fixtures/macos_library_load_probe.c"
            subprocess.run(["xcrun", "clang", str(probe_source), "-o", str(executable)], check=True, capture_output=True)
            subprocess.run(["codesign", "--force", "--deep", "--options", "runtime", "--timestamp=none", "--sign", "-", str(app)], check=True, capture_output=True)
            baseline_signing = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True, check=True)
            self.assertIn("runtime", baseline_signing.stderr)
            self.assertIn("Signature=adhoc", baseline_signing.stderr)
            system = subprocess.run([str(executable), "/usr/lib/libSystem.B.dylib"], capture_output=True)
            self.assertEqual(system.returncode, 0)
            before = subprocess.run([str(executable), str(library)], capture_output=True, text=True)
            # GitHub 的 macOS 15 ARM64 环境在添加例外前也可加载，不能把必须拒绝当成跨环境保证。
            # 无论基线是否拒绝，后续的实际加载、runtime 和唯一权限检查都必须执行。
            if before.returncode == 0:
                self.assertIn("library loaded", before.stdout)
            else:
                self.assertEqual(before.returncode, 1, before.stderr)
                self.assertRegex(before.stderr, r"Team ID|Library Validation")
            subprocess.run(["bash", str(ROOT / "tools/release/sign_macos_local_test.sh"), str(app)], check=True, capture_output=True)
            after = subprocess.run([str(executable), str(library)], capture_output=True, text=True)
            self.assertEqual(after.returncode, 0, after.stderr)
            self.assertIn("library loaded", after.stdout)
            signing = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True, check=True)
            self.assertIn("runtime", signing.stderr)
            self.assertIn("Signature=adhoc", signing.stderr)
            entitlements = subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", str(app)], stderr=subprocess.DEVNULL)
            self.assertEqual(plistlib.loads(entitlements), {"com.apple.security.cs.disable-library-validation": True})

    def test_updater_architecture_command_accepts_real_binary_and_rejects_missing_slice(self):
        source = (ROOT / "tools/release/verify_macos_updater.sh").read_text()
        command = next(line.strip() for line in source.splitlines() if "lipo " in line and "-verify_arch" in line)
        executable = "/usr/bin/true"
        arch = subprocess.check_output(["lipo", "-archs", executable], text=True).split()[0]
        script = 'set -euo pipefail\nexecutable="$1"\narch="$2"\n' + command
        valid = subprocess.run(["/bin/bash", "-c", script, "arch-test", executable, arch], capture_output=True)
        self.assertEqual(valid.returncode, 0, valid.stderr.decode())
        invalid = subprocess.run(["/bin/bash", "-c", script, "arch-test", executable, "ppc"], capture_output=True)
        self.assertNotEqual(invalid.returncode, 0)

    def test_identity_fields_match_each_bundle_without_changing_permissions(self):
        source = PACKAGE.read_text(encoding="utf-8")
        functions = []
        for name in ["set_plist_string", "set_signing_identity_entitlements"]:
            match = re.search(rf"^{name}\(\) \{{\n.*?^\}}", source, re.M | re.S)
            self.assertIsNotNone(match, name)
            functions.append(match.group())
        for target, bundle_id in [
            ("DsmMac", "example.mount"),
            ("DsmFileProvider", "example.mount.fileprovider"),
        ]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                original = plistlib.loads(
                    (ROOT / f"apple/Apps/DsmMac/SupportingFiles/{target}.entitlements").read_bytes()
                )
                path = Path(directory) / "expanded.entitlements"
                path.write_bytes(plistlib.dumps(original))
                script = "\n".join(functions) + "\n" + """
set -euo pipefail
PLIST_BUDDY=/usr/libexec/PlistBuddy
TEAM_IDENTIFIER=TESTTEAM01
set_signing_identity_entitlements "$1" "$2"
set_signing_identity_entitlements "$1" "$2"
"""
                subprocess.run(
                    ["/bin/bash", "-c", script, "signing-test", str(path), bundle_id],
                    check=True, capture_output=True, text=True,
                )
                result = plistlib.loads(path.read_bytes())
                self.assertEqual(result.pop("com.apple.application-identifier"), f"TESTTEAM01.{bundle_id}")
                self.assertEqual(result.pop("com.apple.developer.team-identifier"), "TESTTEAM01")
                self.assertEqual(result, original)


if __name__ == "__main__":
    unittest.main()
