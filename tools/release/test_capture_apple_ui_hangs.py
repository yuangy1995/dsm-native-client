#!/usr/bin/env python3
"""验证启动诊断的进程边界、只读采样及原始输出保留。"""

import io
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

from tools.release.capture_apple_ui_hangs import HangSampler, IDLE_TIMEOUT, forward_output


SCRIPT = Path(__file__).with_name("capture_apple_ui_hangs.py")


class AppleUIHangCaptureTests(unittest.TestCase):
    def test_cli_forwards_output_without_collecting_diagnostics_for_normal_tests(self):
        content = b"Test started\n__XCODEBUILD__\0test-without-building\0\nTest passed\n"
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--device", "unused", "--output", "/unused"],
            input=content, capture_output=True, check=True,
        )
        self.assertEqual(result.stdout, content)
        self.assertEqual(result.stderr, b"")

    def test_capture_does_not_block_output_and_is_finished_before_returning(self):
        started = threading.Event()
        release = threading.Event()
        finished = threading.Event()
        output = io.BytesIO()

        class Sampler:
            def capture(self):
                started.set()
                release.wait(timeout=5)
                finished.set()

        def lines():
            yield IDLE_TIMEOUT + b"\n"
            self.assertTrue(started.wait(timeout=2))
            try:
                yield b"test continued\n"
                self.assertTrue(output.getvalue().endswith(b"test continued\n"))
                self.assertFalse(finished.is_set())
            finally:
                release.set()

        forward_output(lines(), output, Sampler())
        self.assertTrue(finished.is_set())

    def test_only_matching_device_app_and_explicit_fixture_are_sampled_once_per_process(self):
        container = "/synthetic simulator/App.app"
        process = f"{container}/DsmMobile"
        listing = "\n".join([
            f"111 /other-device/App.app/DsmMobile --ui-fixture",
            f"112 {process} --ordinary-launch",
            f"113 {process}-other --ui-fixture",
            f"114 {process} --ui-fixture-other",
            f"115 {process} --ui-fixture",
            f"116 {process} --ui-files-fixture",
            f"117 {process} --ui-share-fixture",
        ])
        calls = []
        reports = []

        def run(arguments, **options):
            calls.append((arguments, options))
            if arguments[0] == "xcrun":
                self.assertEqual(arguments[3], "selected-device")
                return subprocess.CompletedProcess(arguments, 0, stdout=container + "\n")
            if arguments[0] == "ps":
                return subprocess.CompletedProcess(arguments, 0, stdout=listing)
            Path(arguments[-1]).write_text("synthetic stack")
            return subprocess.CompletedProcess(arguments, 0, stdout="")

        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=run, report=reports.append)
            sampler.capture()
            sampler.capture()
            self.assertEqual(sorted(path.name for path in Path(directory).iterdir()), [
                "DsmMobile-115.sample.txt", "DsmMobile-116.sample.txt", "DsmMobile-117.sample.txt",
            ])
        samples = [(arguments, options) for arguments, options in calls if arguments[0] == "/usr/bin/sample"]
        self.assertEqual(len(samples), 3)
        for arguments, options in samples:
            self.assertEqual(arguments[2:5], ["3", "10", "-file"])
            self.assertEqual(options["timeout"], 45)
        self.assertEqual(len(reports), 3)

    def test_timeout_identifies_the_failed_stage_without_exposing_command_output(self):
        for command, stage in [("xcrun", "定位测试应用"), ("ps", "读取测试进程"),
                               ("/usr/bin/sample", "采集调用栈")]:
            with self.subTest(command=command), tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
                calls = []
                reports = []

                def run(arguments, **options):
                    calls.append(arguments[0])
                    if arguments[0] == command:
                        raise subprocess.TimeoutExpired(arguments, options["timeout"],
                                                        output="unfiltered process data", stderr="unfiltered error")
                    output = "/selected/App.app\n" if arguments[0] == "xcrun" else "123 /selected/App.app/DsmMobile --ui-fixture\n"
                    return subprocess.CompletedProcess(arguments, 0, stdout=output)

                HangSampler("selected-device", directory, run=run, report=reports.append).capture()
                self.assertEqual(calls[-1], command)
                self.assertEqual(len(reports), 1)
                self.assertIn(stage, reports[0])
                self.assertIn("TimeoutExpired", reports[0])
                self.assertIn("原测试结果仍保留", reports[0])
                self.assertNotIn("unfiltered", reports[0])

    def test_container_lookup_denial_does_not_scan_or_sample_other_processes(self):
        calls = []
        reports = []

        def run(arguments, **options):
            calls.append(arguments)
            raise subprocess.CalledProcessError(1, arguments, stderr="unfiltered diagnostic output")

        HangSampler("selected-device", "/unused", run=run, report=reports.append).capture()
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(reports), 1)
        self.assertIn("原测试结果仍保留", reports[0])
        self.assertNotIn("unfiltered", reports[0])

    def test_unresolved_container_path_does_not_fall_back_to_process_name(self):
        calls = []
        reports = []

        def run(arguments, **options):
            calls.append(arguments)
            return subprocess.CompletedProcess(arguments, 0, stdout="")

        HangSampler("selected-device", "/unused", run=run, report=reports.append).capture()
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(reports), 1)

    def test_sample_failure_is_reported_without_retrying_or_losing_output(self):
        calls = []
        reports = []

        def run(arguments, **options):
            calls.append(arguments)
            if arguments[0] == "xcrun":
                return subprocess.CompletedProcess(arguments, 0, stdout="/selected/App.app\n")
            if arguments[0] == "ps":
                return subprocess.CompletedProcess(arguments, 0, stdout="123 /selected/App.app/DsmMobile --ui-fixture\n")
            raise PermissionError("sampling denied")

        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=run, report=reports.append)
            content = (IDLE_TIMEOUT + b"\n") * 2 + b"original test failed\n"
            output = io.BytesIO()
            forward_output(io.BytesIO(content), output, sampler)
        self.assertEqual(output.getvalue(), content)
        self.assertEqual(sum(arguments[0] == "/usr/bin/sample" for arguments in calls), 1)
        self.assertEqual(len(reports), 1)


if __name__ == "__main__":
    unittest.main()
