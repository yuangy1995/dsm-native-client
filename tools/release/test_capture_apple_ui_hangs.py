#!/usr/bin/env python3
"""验证界面诊断的触发范围、进程边界、有限重试及原始输出保留。"""

import contextlib
import io
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

from tools.release.capture_apple_ui_hangs import (
    AUTOMATION_SESSION, BUNDLE_ID, HangSampler, IDLE_TIMEOUT, MAX_CAPTURE_REQUESTS,
    MAX_SAMPLE_ATTEMPTS, UIHangMonitor, forward_output,
)


SCRIPT = Path(__file__).with_name("capture_apple_ui_hangs.py")


class SyntheticProcesses:
    """模拟公开命令接口，允许在路径预取与正式采样之间更换或移除进程。"""

    def __init__(self, container="/selected/App.app", processes=None):
        self.container = container
        self.processes = processes or {"123": f"{container}/DsmMobile --ui-fixture"}
        self.calls = []
        self.lookup_error = None
        self.sample_error = None

    def __call__(self, arguments, **options):
        self.calls.append((arguments, options))
        if arguments[0] == "xcrun":
            if self.lookup_error:
                raise self.lookup_error
            content = self.container + "\n"
        elif arguments[:2] == ["ps", "-axo"]:
            content = "\n".join(f"{pid} {command}" for pid, command in self.processes.items())
        elif arguments[:2] == ["ps", "-p"]:
            content = self.processes.get(arguments[2], "")
        else:
            if self.sample_error:
                raise self.sample_error
            Path(arguments[-1]).write_text("synthetic stack")
            content = ""
        return subprocess.CompletedProcess(arguments, 0, stdout=content)

    @property
    def samples(self):
        return [(args, options) for args, options in self.calls if args[0] == "/usr/bin/sample"]


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
        started, release, finished = threading.Event(), threading.Event(), threading.Event()
        output = io.BytesIO()

        class Sampler:
            def capture(self, reason):
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

    def test_path_and_process_preparation_are_nonblocking_and_finish_before_capture(self):
        started, release = threading.Event(), threading.Event()
        output, calls = io.BytesIO(), []

        class Sampler:
            def prepare(self, remember_processes=True):
                calls.append("prepare")
                started.set()
                release.wait(timeout=5)
                calls.append("ready")

            def capture(self, reason):
                calls.append("capture")

        def lines():
            yield AUTOMATION_SESSION + b"\n"
            self.assertTrue(started.wait(timeout=2))
            try:
                yield b"test continued\n"
                self.assertTrue(output.getvalue().endswith(b"test continued\n"))
                yield IDLE_TIMEOUT + b"\n"
                self.assertEqual(calls, ["prepare"])
            finally:
                release.set()

        forward_output(lines(), output, Sampler())
        self.assertEqual(calls, ["prepare", "ready", "capture"])

    def test_query_and_launch_failures_trigger_capture_without_idle_timeout_message(self):
        for message, reason in [
            (b"Failed to get matching snapshots: Timed out while evaluating UI query.", "界面快照查询超时"),
            (b"Failed to launch the application", "测试应用启动失败"),
            (b"Failed to establish application accessibility", "测试应用启动失败"),
        ]:
            with self.subTest(message=message):
                calls = []

                class Sampler:
                    def capture(self, value):
                        calls.append(value)

                output = io.BytesIO()
                forward_output(io.BytesIO(message + b"\n"), output, Sampler())
                self.assertEqual(calls, [reason])
                self.assertEqual(output.getvalue(), message + b"\n")

    def test_watchdog_samples_silent_ui_query_before_its_timeout_and_only_once(self):
        captured = threading.Event()
        calls = []

        class Sampler:
            def capture(self, reason):
                calls.append(reason)
                captured.set()

        monitor = UIHangMonitor(Sampler(), quiet_seconds=0.02)
        try:
            monitor.observe(b'    t =    22.77s Checking existence of "files.toolbar.more" Any\n')
            self.assertTrue(captured.wait(timeout=2))
            captured.clear()
            self.assertFalse(captured.wait(timeout=0.08))
        finally:
            monitor.close()
        self.assertEqual(calls, ["启动或界面查询阶段持续无输出"])

    def test_watchdog_arms_for_launch_and_idle_but_not_build_business_wait_or_finished_test(self):
        launch = b"    t = 0.08s Launch " + BUNDLE_ID.encode() + b"\n"
        idle = b"    t = 1.0s Wait for " + BUNDLE_ID.encode() + b" to idle\n"
        for lines, expected in [
            ([launch], True),
            ([b"    t = 2.0s " + AUTOMATION_SESSION + b"\n"], True),
            ([idle], True),
            ([b"CompileSwift normal arm64\n"], False),
            ([launch, b"    t = 5.0s Waiting 120.0s for upload completion\n"], False),
            ([launch, b"Test Case 'synthetic test' passed.\n"], False),
            ([launch, b"    t = 10.0s Tear Down\n"], False),
        ]:
            with self.subTest(lines=lines):
                captured = threading.Event()

                class Sampler:
                    def prepare(self, remember_processes=True):
                        pass

                    def capture(self, reason):
                        captured.set()

                monitor = UIHangMonitor(Sampler(), quiet_seconds=0.02)
                try:
                    for line in lines:
                        monitor.observe(line)
                    self.assertEqual(captured.wait(timeout=2 if expected else 0.08), expected)
                finally:
                    monitor.close()

    def test_repeated_notifications_do_not_accumulate_an_unbounded_capture_queue(self):
        started, release = threading.Event(), threading.Event()
        captures = []

        class Sampler:
            def capture(self, reason):
                captures.append(reason)
                started.set()
                release.wait(timeout=5)

        monitor = UIHangMonitor(Sampler())
        try:
            monitor.observe(IDLE_TIMEOUT)
            self.assertTrue(started.wait(timeout=2))
            for _ in range(1000):
                monitor.observe(IDLE_TIMEOUT)
        finally:
            release.set()
            monitor.close()
        self.assertEqual(len(captures), 2)

    def test_unexpected_diagnostic_error_does_not_lose_output_or_change_forwarder_result(self):
        class Sampler:
            def capture(self, reason):
                raise RuntimeError("unfiltered diagnostic details")

        content = IDLE_TIMEOUT + b"\noriginal test failure\n"
        output, errors = io.BytesIO(), io.StringIO()
        with contextlib.redirect_stderr(errors):
            forward_output(io.BytesIO(content), output, Sampler())
        self.assertEqual(output.getvalue(), content)
        self.assertIn("RuntimeError", errors.getvalue())
        self.assertNotIn("unfiltered", errors.getvalue())

    def test_prepared_exact_path_and_pid_survive_lookup_timeout_without_sampling_other_apps(self):
        processes = SyntheticProcesses(processes={
            "111": "/other-device/App.app/DsmMobile --ui-fixture",
            "112": "/selected/App.app/DsmMobile --ordinary-launch",
            "113": "/selected/App.app/DsmMobile --ui-fixture-other",
            "114": "/selected/App.app/DsmMobile --ui-fixture",
        })
        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=processes, report=lambda _: None)
            sampler.prepare()
            self.assertEqual(list(sampler.processes), ["114"])
            processes.lookup_error = subprocess.TimeoutExpired("lookup", 10)
            sampler.prepare()
            sampler.capture()
            self.assertEqual([p.name for p in Path(directory).iterdir()], ["DsmMobile-114-1.sample.txt"])
        self.assertEqual([args[1] for args, _ in processes.samples], ["114"])
        self.assertEqual(sum(args[0] == "xcrun" for args, _ in processes.calls), 2)

    def test_new_launch_replaces_prepared_path_and_rejects_the_old_process(self):
        processes = SyntheticProcesses("/old/App.app", processes={
            "111": "/old/App.app/DsmMobile --ui-fixture",
            "112": "/new/App.app/DsmMobile --ui-fixture",
        })
        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=processes, report=lambda _: None)
            sampler.prepare()
            processes.container = "/new/App.app"
            sampler.prepare()
            sampler.capture()
        self.assertEqual([args[1] for args, _ in processes.samples], ["112"])

    def test_launch_preparation_drops_old_pid_before_new_automation_session(self):
        processes = SyntheticProcesses()
        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=processes, report=lambda _: None)
            sampler.prepare()
            self.assertEqual(list(sampler.processes), ["123"])
            sampler.prepare(remember_processes=False)
            self.assertEqual(sampler.processes, {})
            processes.processes = {"124": "/selected/App.app/DsmMobile --ui-fixture"}
            sampler.capture("测试应用启动失败")
        self.assertEqual([args[1] for args, _ in processes.samples], ["124"])

    def test_prepared_pid_is_revalidated_before_sampling_and_never_follows_a_new_process(self):
        for replacement in [None, "/other-device/App.app/DsmMobile --ui-fixture",
                            "/selected/App.app/DsmMobile --ordinary-launch"]:
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
                processes = SyntheticProcesses()
                sampler = HangSampler("selected-device", directory, run=processes, report=lambda _: None)
                sampler.prepare()
                processes.processes = {"124": "/selected/App.app/DsmMobile --ui-fixture"}
                if replacement:
                    processes.processes["123"] = replacement
                sampler.capture()
                self.assertEqual(processes.samples, [])

    def test_lookup_denial_or_invalid_path_clears_previously_prepared_identity(self):
        for result in ["denied", "", "relative/App.app"]:
            with self.subTest(result=result):
                processes, reports = SyntheticProcesses(), []
                sampler = HangSampler("selected-device", "/unused", run=processes, report=reports.append)
                sampler.prepare()
                processes.calls.clear()
                if result == "denied":
                    processes.lookup_error = subprocess.CalledProcessError(1, "lookup", stderr="unfiltered diagnostic output")
                else:
                    processes.container = result
                sampler.prepare()
                self.assertIsNone(sampler.executable)
                self.assertEqual(sampler.processes, {})
                sampler.capture()
                self.assertEqual([args[0] for args, _ in processes.calls], ["xcrun", "xcrun"])
                self.assertEqual(len(reports), 1)
                self.assertNotIn("unfiltered", reports[0])

    def test_only_matching_device_app_and_explicit_fixture_are_sampled_once_per_process(self):
        container = "/synthetic simulator/App.app"
        process = f"{container}/DsmMobile"
        processes = SyntheticProcesses(container, processes={
            "111": "/other-device/App.app/DsmMobile --ui-fixture",
            "112": f"{process} --ordinary-launch",
            "113": f"{process}-other --ui-fixture",
            "114": f"{process} --ui-fixture-other",
            "115": f"{process} --ui-fixture",
            "116": f"{process} --ui-files-fixture",
            "117": f"{process} --ui-share-fixture",
        })
        reports = []
        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=processes, report=reports.append)
            sampler.capture()
            sampler.capture()
            self.assertEqual(sorted(path.name for path in Path(directory).iterdir()), [
                "DsmMobile-115-1.sample.txt", "DsmMobile-116-1.sample.txt", "DsmMobile-117-1.sample.txt",
            ])
        self.assertEqual(len(processes.samples), 3)
        for arguments, options in processes.samples:
            self.assertEqual(arguments[2:5], ["3", "10", "-file"])
            self.assertEqual(options["timeout"], 45)
        self.assertTrue(all(args[3] == "selected-device" for args, _ in processes.calls if args[0] == "xcrun"))
        self.assertEqual(len(reports), 3)

    def test_timeout_identifies_failed_stage_without_exposing_command_output(self):
        for command, stage in [("xcrun", "定位测试应用"), ("ps", "读取测试进程"),
                               ("/usr/bin/sample", "采集调用栈")]:
            with self.subTest(command=command), tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
                processes, reports = SyntheticProcesses(), []

                def run(arguments, **options):
                    if arguments[0] == command:
                        raise subprocess.TimeoutExpired(arguments, options["timeout"],
                                                        output="unfiltered process data", stderr="unfiltered error")
                    return processes(arguments, **options)

                HangSampler("selected-device", directory, run=run, report=reports.append).capture()
                self.assertEqual(len(reports), 1)
                self.assertIn(stage, reports[0])
                self.assertIn("TimeoutExpired", reports[0])
                self.assertIn("原测试结果仍保留", reports[0])
                self.assertNotIn("unfiltered", reports[0])

    def test_sample_timeout_can_retry_once_and_success_is_not_sampled_again(self):
        processes, reports = SyntheticProcesses(), []
        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=processes, report=reports.append)
            processes.sample_error = subprocess.TimeoutExpired("sample", 45)
            sampler.capture()
            self.assertNotIn("123", sampler.sampled)
            processes.sample_error = None
            sampler.capture()
            sampler.capture()
            self.assertTrue(Path(directory, "DsmMobile-123-2.sample.txt").exists())
        self.assertEqual(len(processes.samples), 2)
        self.assertIn("123", sampler.sampled)
        self.assertEqual(len(reports), 2)

    def test_persistent_sample_failure_has_per_process_and_total_request_limits(self):
        processes, reports = SyntheticProcesses(), []
        processes.sample_error = PermissionError("unfiltered diagnostic output")
        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=processes, report=reports.append)
            for _ in range(MAX_CAPTURE_REQUESTS + 10):
                sampler.capture()
        self.assertEqual(len(processes.samples), 2)
        self.assertEqual(sum(args[0] == "xcrun" for args, _ in processes.calls), MAX_CAPTURE_REQUESTS)
        self.assertEqual(len(reports), 2)
        self.assertNotIn("unfiltered", " ".join(reports))

    def test_total_sample_limit_applies_across_new_processes(self):
        processes = SyntheticProcesses(processes={
            str(pid): "/selected/App.app/DsmMobile --ui-fixture"
            for pid in range(100, 100 + MAX_SAMPLE_ATTEMPTS + 5)
        })
        with tempfile.TemporaryDirectory(prefix="lanstash-hang-test-") as directory:
            sampler = HangSampler("selected-device", directory, run=processes, report=lambda _: None)
            sampler.capture()
            sampler.capture()
        self.assertEqual(len(processes.samples), MAX_SAMPLE_ATTEMPTS)


if __name__ == "__main__":
    unittest.main()
