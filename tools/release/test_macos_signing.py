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
