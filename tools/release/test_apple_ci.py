#!/usr/bin/env python3
"""验证移动测试分组执行的实际参数，确保两端完整覆盖且失败可见。"""

import os
import re
import subprocess
import textwrap
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/apple-build.yml"


class AppleCIShardTests(unittest.TestCase):
    def run_selection(self, suite, exit_code=0, second_exit_code=None):
        source = WORKFLOW.read_text()
        step = source.split("      - name: 分组运行全部移动单元与界面回归\n", 1)[1].split("\n      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        stub = textwrap.dedent('''\
            synthetic_call=0
            xcodebuild() {
              printf "%s\\0" __XCODEBUILD__ "$@"
              synthetic_call=$((synthetic_call + 1))
              if [[ "$synthetic_call" -eq 1 ]]; then return "$SYNTHETIC_BUILD_EXIT"; fi
              return "$SYNTHETIC_SECOND_EXIT"
            }
        ''')
        environment = dict(os.environ, MOBILE_SUITE=suite, MOBILE_TARGET=f"synthetic-{suite}",
                           MOBILE_DEVICE="synthetic-device", RUNNER_TEMP="/synthetic root",
                           SYNTHETIC_BUILD_EXIT=str(exit_code),
                           SYNTHETIC_SECOND_EXIT=str(exit_code if second_exit_code is None else second_exit_code))
        return subprocess.run(["bash", "-euo", "pipefail", "-c", stub + script], env=environment, capture_output=True)

    def invocations(self, result):
        return [call.rstrip("\0").split("\0")
                for call in result.stdout.decode().split("__XCODEBUILD__\0")[1:]]

    def included_classes(self, arguments, suites):
        included = [value.split(":", 1)[1] for value in arguments if value.startswith("-only-testing:")]
        excluded = [value.split(":", 1)[1] for value in arguments if value.startswith("-skip-testing:")]
        return {name for name in suites
                if any(name == value or name.startswith(value + "/") for value in included)
                and not any(name == value or name.startswith(value + "/") for value in excluded)}

    def test_each_device_runs_every_test_class_in_exactly_one_shard(self):
        source = WORKFLOW.read_text()
        matrix = source.split("      matrix:\n", 1)[1].split("    steps:\n", 1)[0]
        rows = re.findall(r"- target: (\S+)\n\s+family: (\S+)\n\s+suite: (\S+)", matrix)
        self.assertEqual(len(rows), 8)
        self.assertEqual(len({target for target, _, _ in rows}), 8)
        self.assertEqual(Counter(family for _, family, _ in rows), {"iPhone": 4, "iPad": 4})
        suites = set()
        for directory, target in [("Tests", "DsmMobileTests"), ("UITests", "DsmMobileUITests")]:
            for path in (ROOT / "apple/Apps/DsmMobile" / directory).glob("*.swift"):
                suites.update(f"{target}/{name}" for name in re.findall(r"class\s+(\w+)\s*:\s*XCTestCase\b", path.read_text()))
        self.assertIn("DsmMobileUITests/MobileWorkspaceUITests", suites)
        self.assertGreater(len(suites), 20)
        for family in ["iPhone", "iPad"]:
            coverage = Counter()
            for _, device, suite in rows:
                if device != family:
                    continue
                result = self.run_selection(suite)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                calls = self.invocations(result)
                self.assertEqual(len(calls), 2 if suite == "modules" else 1)
                for index, arguments in enumerate(calls):
                    self.assertEqual(arguments[0], "test-without-building")
                    suffix = "-system" if suite == "modules" and index == 0 else ""
                    self.assertIn(f"/synthetic root/DsmMobile-synthetic-{suite}{suffix}.xcresult", arguments)
                    coverage.update(self.included_classes(arguments, suites))
            self.assertEqual(coverage, Counter({name: 1 for name in suites}), family)

    def test_system_integration_runs_first_with_its_own_result(self):
        result = self.run_selection("modules")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        calls = self.invocations(result)
        self.assertEqual(len(calls), 2)
        system_suites = {f"DsmMobileUITests/{name}" for name in (
            "MobileFilesProviderUITests", "MobileShareExtensionUITests", "MobileTransferBackgroundUITests"
        )}
        self.assertEqual({argument.split(":", 1)[1] for argument in calls[0]
                          if argument.startswith("-only-testing:")}, system_suites)
        self.assertEqual(self.included_classes(calls[1], system_suites), set())

    def test_either_segment_failure_is_preserved_and_remaining_tests_still_run(self):
        for first, second in [(65, 0), (0, 66), (65, 66)]:
            with self.subTest(first=first, second=second):
                result = self.run_selection("modules", exit_code=first, second_exit_code=second)
                self.assertEqual(result.returncode, first or second, result.stderr.decode())
                self.assertEqual(len(self.invocations(result)), 2)

    def test_test_failure_remains_a_failed_job(self):
        for suite in ["workspace", "modules", "administration", "services"]:
            result = self.run_selection(suite, exit_code=65)
            self.assertEqual(result.returncode, 65)

    def test_unknown_shard_fails_without_running_tests(self):
        result = self.run_selection("unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
