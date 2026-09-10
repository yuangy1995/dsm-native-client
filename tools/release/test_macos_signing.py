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
    def test_distribution_architecture_matches_both_app_and_extension(self):
        source = (ROOT / "tools/release/verify_macos_distribution.sh").read_text()
        gate = source.split('case "$DMG_PATH" in\n', 1)[1].split('[[ -f "$APP_PROFILE_PATH" ]]', 1)[0]
        gate = 'case "$DMG_PATH" in\n' + gate
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = root / "probe.c"
            code.write_text("int main(void) { return 0; }\n")
            app = root / "LanStash.app"
            extension = app / "Contents/PlugIns/LanStashFileProvider.appex"
            main = app / "Contents/MacOS/LanStash"
            helper = extension / "Contents/MacOS/LanStashFileProvider"
            main.parent.mkdir(parents=True)
            helper.parent.mkdir(parents=True)
            for arch in ["arm64", "x86_64"]:
                subprocess.run(["xcrun", "clang", "-arch", arch, str(code), "-o", str(main)], check=True, capture_output=True)
                subprocess.run(["xcrun", "clang", "-arch", arch, str(code), "-o", str(helper)], check=True, capture_output=True)
                script = 'set -euo pipefail\nfail() { exit 1; }\nAPP_PATH="$1"\nFILE_PROVIDER_PATH="$2"\nDMG_PATH="$3"\n' + gate
                for label, expected in [(arch, 0), ("x86_64" if arch == "arm64" else "arm64", 1)]:
                    result = subprocess.run(["/bin/bash", "-c", script, "arch", str(app), str(extension), f"LanStash-1.0.3-{label}.dmg"], capture_output=True)
                    self.assertEqual(result.returncode, expected)
                helper.write_bytes(b"not an executable")
                result = subprocess.run(["/bin/bash", "-c", script, "arch", str(app), str(extension), f"LanStash-1.0.3-{arch}.dmg"], capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_daily_ci_checks_and_uploads_isolated_test_artifacts(self):
        source = (ROOT / ".github/workflows/apple-build.yml").read_text()
        self.assertIn('"apple/Apps/DsmMac/dist/local-test/LanStash Test.app"', source)
        self.assertIn("apple/Apps/DsmMac/dist/local-test/LanStash-*.dmg", source)
        self.assertIn("apple/Apps/DsmMac/dist/local-test/*.app", source)
        self.assertIn("apple/Apps/DsmMac/dist/local-test/*.dmg", source)
        self.assertNotIn("apple/Apps/DsmMac/dist/LanStash.app", source)

    def test_local_packaging_has_fixed_isolated_identity_and_never_auto_launches(self):
        source = PACKAGE.read_text()
        start = source.index('if [[ "$SIGNING_IDENTITY" == "-" ]]; then\n    # 本地临时包')
        branch = source[start:source.index("\nfi\n", start) + 4]
        setup = '''
set -euo pipefail
SCRIPT_DIR=/synthetic
SIGNING_IDENTITY="$1"
MAC_APP_BUNDLE_ID=formal-app
MAC_FILE_PROVIDER_BUNDLE_ID=formal-extension
MAC_APP_GROUP_ID=formal-group
SHARED_KEYCHAIN_SUFFIX=formal-keychain
DIST_DIR=/formal-output
BUILD_ROOT=/formal-build
RUN_AFTER_PACKAGE=1
'''
        output = '\nprintf "%s\\n" "$MAC_APP_BUNDLE_ID" "$DIST_DIR" "$RUN_AFTER_PACKAGE"\n'
        local = subprocess.check_output(["bash", "-c", setup + branch + output, "probe", "-"], text=True)
        self.assertEqual(local.splitlines(), ["io.github.qwertyuiop1995.dsmnativeclient.macos.localtest", "/synthetic/dist/local-test", "0"])
        formal = subprocess.check_output(["bash", "-c", setup + branch + output, "probe", "Developer ID Application: Synthetic"], text=True)
        self.assertEqual(formal.splitlines(), ["formal-app", "/formal-output", "1"])

    def test_test_bundle_resource_preparation_rejects_formal_app(self):
        with tempfile.TemporaryDirectory(prefix="lanstash-isolation-test-") as directory:
            app = Path(directory) / "Test.app"
            (app / "Contents").mkdir(parents=True)
            plist = app / "Contents/Info.plist"
            original = {"CFBundleIdentifier": "formal-app", "CFBundleName": "LanStash", "CFBundleDisplayName": "LanStash"}
            plist.write_bytes(plistlib.dumps(original))
            command = ["bash", str(ROOT / "tools/release/prepare_macos_local_test.sh"), str(app)]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(plistlib.loads(plist.read_bytes()), original)
            original["CFBundleIdentifier"] = "io.github.qwertyuiop1995.dsmnativeclient.macos.localtest"
            plist.write_bytes(plistlib.dumps(original))
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(plistlib.loads(plist.read_bytes())["CFBundleName"], "LanStash Test")
            for locale, name in [("en", "LanStash Test"), ("zh-Hans", "岚仓测试版")]:
                resource = app / f"Contents/Resources/{locale}.lproj/InfoPlist.strings"
                data = subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(resource)])
                self.assertEqual(plistlib.loads(data)["CFBundleDisplayName"], name)

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
