"""实际执行工作流的发布入口校验，使用合成环境且不签名、不发布。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class MacOSReleaseGateTests(unittest.TestCase):
    def run_gate(self, **overrides):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/macos-release-verification.yml").read_text()
        section = workflow.split("      - name: 校验发布范围与升级启用条件\n", 1)[1]
        source = section.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
        script = "set -euo pipefail\ngit() { printf '%s\\n' fixture-commit; }\n"
        script += "\n".join(line[10:] for line in source.splitlines())
        env = {
            **os.environ, "PACKAGE_MODE": "release", "PUBLISH_RELEASE": "true",
            "PUBLISH_VALIDATION": "false", "ENABLE_UPDATES": "true", "UPDATE_VALIDATED": "true",
            "SPARKLE_PUBLIC_ED_KEY": "fixture-public", "SPARKLE_PRIVATE_ED_KEY": "fixture-private",
            "GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "macos/v0.2.6", "GITHUB_SHA": "fixture-commit",
            **overrides,
        }
        with tempfile.TemporaryDirectory() as directory:
            env["GITHUB_ENV"] = str(Path(directory) / "env")
            return subprocess.run(["/bin/bash", "-c", script], env=env, capture_output=True).returncode

    def test_validated_formal_tag_is_allowed(self):
        self.assertEqual(self.run_gate(), 0)

    def test_unvalidated_unsigned_wrong_platform_or_mismatched_commit_is_rejected(self):
        for change in [
            {"UPDATE_VALIDATED": "false"}, {"PACKAGE_MODE": "pretest"},
            {"GITHUB_REF_TYPE": "branch"}, {"GITHUB_REF_NAME": "android/v0.2.6"},
            {"GITHUB_SHA": "different-commit"}, {"SPARKLE_PRIVATE_ED_KEY": ""},
            {"SPARKLE_PUBLIC_ED_KEY": ""}, {"PUBLISH_VALIDATION": "true"},
        ]:
            with self.subTest(change=change):
                self.assertNotEqual(self.run_gate(**change), 0)

    def test_validation_channel_requires_formal_package_and_own_tag(self):
        valid = {"PUBLISH_RELEASE": "false", "PUBLISH_VALIDATION": "true",
                 "UPDATE_VALIDATED": "false", "GITHUB_REF_NAME": "macos-validation/v0.2.6"}
        self.assertEqual(self.run_gate(**valid), 0)
        self.assertNotEqual(self.run_gate(**{**valid, "PACKAGE_MODE": "pretest"}), 0)
        self.assertNotEqual(self.run_gate(**{**valid, "GITHUB_REF_NAME": "macos/v0.2.6"}), 0)


if __name__ == "__main__":
    unittest.main()
