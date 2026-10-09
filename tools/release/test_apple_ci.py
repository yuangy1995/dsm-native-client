#!/usr/bin/env python3
"""验证移动测试分组执行的实际参数，确保两端完整覆盖且失败可见。"""

import os
import plistlib
import re
import subprocess
import tempfile
import textwrap
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/apple-build.yml"


class AppleCIShardTests(unittest.TestCase):
    def run_selection(self, suite, exit_code=0, second_exit_code=None, provider_ready_after=1):
        source = WORKFLOW.read_text()
        step = source.split("      - name: 分组运行全部移动单元与界面回归\n", 1)[1].split("\n      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        stub = textwrap.dedent('''\
            xcodebuild() {
              printf "test\\n" >> "$SYNTHETIC_EVENTS"
              printf "%s\\0" __XCODEBUILD__ "$@"
              synthetic_call=$(cat "$SYNTHETIC_CALL_STATE")
              synthetic_call=$((synthetic_call + 1))
              printf "%s" "$synthetic_call" > "$SYNTHETIC_CALL_STATE"
              if [[ "$synthetic_call" -eq 1 ]]; then return "$SYNTHETIC_BUILD_EXIT"; fi
              return "$SYNTHETIC_SECOND_EXIT"
            }
            xcrun() {
              if [[ "$1" == simctl && "$2" == install && "$#" -eq 4 ]]; then
                [[ "$3" == "$MOBILE_DEVICE" && "$4" == "$RUNNER_TEMP/DsmMobile-build/Build/Products/Debug-iphonesimulator/DsmMobile.app" ]] || return 91
                printf "install\\n" >> "$SYNTHETIC_EVENTS"
                return 0
              fi
              if [[ "$1" == simctl && "$2" == spawn && "$#" -eq 6 ]]; then
                [[ "$3" == "$MOBILE_DEVICE" && "$4" == fileproviderctl && "$5" == dump && "$6" == "$SYNTHETIC_PROVIDER_ID" ]] || return 92
                synthetic_probe=$(cat "$SYNTHETIC_PROVIDER_CALL_STATE")
                synthetic_probe=$((synthetic_probe + 1))
                printf "%s" "$synthetic_probe" > "$SYNTHETIC_PROVIDER_CALL_STATE"
                printf "query\\n" >> "$SYNTHETIC_EVENTS"
                printf "providers, filtered by '%s'\\n" "$6"
                if [[ "$SYNTHETIC_PROVIDER_READY_AFTER" -gt 0 && "$synthetic_probe" -ge "$SYNTHETIC_PROVIDER_READY_AFTER" ]]; then
                  printf "%s\\n" "$6"
                fi
                return 0
              fi
              return 93
            }
            sleep() {
              [[ "$#" -eq 1 && "$1" == 2 ]] || return 94
              printf "sleep\\n" >> "$SYNTHETIC_EVENTS"
            }
        ''')
        environment = dict(os.environ, MOBILE_SUITE=suite, MOBILE_TARGET=f"synthetic-{suite}",
                           MOBILE_DEVICE="synthetic-device",
                           GITHUB_WORKSPACE=str(ROOT),
                           SYNTHETIC_BUILD_EXIT=str(exit_code),
                           SYNTHETIC_SECOND_EXIT=str(exit_code if second_exit_code is None else second_exit_code),
                           SYNTHETIC_PROVIDER_ID="test.example.files",
                           SYNTHETIC_PROVIDER_READY_AFTER=str(provider_ready_after))
        with tempfile.TemporaryDirectory(prefix="lanstash-ci-shard-") as directory:
            # 使用真实合成 plist 和带空格的路径，验证工作流读取与参数引用。
            self.runner_temp = str(Path(directory) / "synthetic root")
            environment["RUNNER_TEMP"] = self.runner_temp
            info = Path(self.runner_temp) / "DsmMobile-build/Build/Products/Debug-iphonesimulator/DsmMobile.app/PlugIns/DsmFiles.appex/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": environment["SYNTHETIC_PROVIDER_ID"]}))
            counter = Path(directory) / "call-count"
            counter.write_text("0")
            environment["SYNTHETIC_CALL_STATE"] = str(counter)
            probes = Path(directory) / "probe-count"
            probes.write_text("0")
            environment["SYNTHETIC_PROVIDER_CALL_STATE"] = str(probes)
            events = Path(directory) / "events"
            events.touch()
            environment["SYNTHETIC_EVENTS"] = str(events)
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", stub + script], env=environment, capture_output=True)
            self.prepare_events = events.read_text().splitlines()
            return result

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
                    self.assertIn(f"{self.runner_temp}/DsmMobile-synthetic-{suite}{suffix}.xcresult", arguments)
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

    def test_provider_must_be_discovered_before_system_tests(self):
        result = self.run_selection("modules", provider_ready_after=3)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(self.prepare_events, ["install", "query", "sleep", "query", "sleep", "query", "test", "test"])
        self.assertEqual(len(self.invocations(result)), 2)

    def test_discovery_failure_is_preserved_and_remaining_modules_still_run(self):
        for remaining_exit in [0, 66]:
            with self.subTest(remaining_exit=remaining_exit):
                result = self.run_selection("modules", exit_code=remaining_exit, provider_ready_after=0)
                self.assertEqual(result.returncode, 1, result.stderr.decode())
                self.assertEqual(self.prepare_events.count("install"), 1)
                self.assertEqual(self.prepare_events.count("query"), 60)
                self.assertEqual(self.prepare_events.count("sleep"), 60)
                self.assertEqual(self.prepare_events[-1], "test")
                calls = self.invocations(result)
                self.assertEqual(len(calls), 1)
                self.assertIn(f"{self.runner_temp}/DsmMobile-synthetic-modules.xcresult", calls[0])
                self.assertIn("-skip-testing:DsmMobileUITests/MobileFilesProviderUITests", calls[0])

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
