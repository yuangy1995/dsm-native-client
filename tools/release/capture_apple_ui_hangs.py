#!/usr/bin/env python3
"""原样转发 Xcode 测试输出，在启动、空闲或界面查询卡顿时只读采样合成测试 App。"""

import argparse
import re
import subprocess
import sys
import threading
import time
from pathlib import Path


BUNDLE_ID = "io.github.qwertyuiop1995.dsmnativeclient.mobile"
IDLE_TIMEOUT = b"App event loop idle notification not received"
AUTOMATION_SESSION = b"Setting up automation session"
FIXTURE_ARGUMENTS = {"--ui-fixture", "--ui-files-fixture", "--ui-share-fixture"}
QUERY_FAILURES = (b"Timed out while evaluating UI query", b"Failed to get matching snapshots")
LAUNCH_FAILURES = (b"Failed to launch", b"Failed to establish application accessibility")
UI_ACTION = re.compile(rb"\bt =\s*[\d.]+s\s+(.*)")
QUIET_SECONDS = 20
MAX_CAPTURE_REQUESTS = 8
MAX_SAMPLE_ATTEMPTS = 8
MAX_PROCESS_ATTEMPTS = 2


class HangSampler:
    def __init__(self, device, output, run=subprocess.run, report=None):
        self.device = device
        self.output = Path(output)
        self.run = run
        self.report = report or (lambda message: print(message, file=sys.stderr, flush=True))
        self.sampled = set()
        self.attempts = {}
        self.capture_requests = 0
        self.sample_attempts = 0
        self.executable = None
        self.processes = {}

    def _resolve_executable(self):
        container = self.run(
            ["xcrun", "simctl", "get_app_container", self.device, BUNDLE_ID, "app"],
            capture_output=True, text=True, check=True, timeout=10,
        ).stdout.strip()
        if not container or not Path(container).is_absolute():
            return None
        return str(Path(container) / "DsmMobile")

    def _fixture_processes(self, executable):
        listing = self.run(
            ["ps", "-axo", "pid=,command=", "-ww"],
            capture_output=True, text=True, check=True, timeout=5,
        ).stdout
        processes = {}
        for line in listing.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2 or not parts[0].isdigit():
                continue
            pid, command = parts
            if command.startswith(executable + " "):
                arguments = command[len(executable) + 1:].split()
                if FIXTURE_ARGUMENTS.intersection(arguments):
                    processes[pid] = command
        return processes

    def prepare(self, remember_processes=True):
        # 模拟器服务在卡顿时曾超时；自动化会话建立时预取精确路径和合成进程身份。
        try:
            self.executable = self._resolve_executable()
        except subprocess.TimeoutExpired:
            # 只在超时时保留已核对路径，拒绝或无效结果必须清除它。
            pass
        except (OSError, subprocess.SubprocessError):
            self.executable = None
        self.processes = {}
        if self.executable and remember_processes:
            try:
                self.processes = self._fixture_processes(self.executable)
            except (OSError, subprocess.SubprocessError):
                pass

    def capture(self, reason="界面空闲超时"):
        # 限制无法定位进程、持续超时和连续多个失败的诊断成本，不影响测试退出码。
        if self.capture_requests >= MAX_CAPTURE_REQUESTS or self.sample_attempts >= MAX_SAMPLE_ATTEMPTS:
            return
        self.capture_requests += 1
        stage = "定位测试应用"
        try:
            executable = self.executable or self._resolve_executable()
            if not executable:
                self.report("移动界面诊断未采集：无法确定当前模拟器的 App 路径。")
                return
            stage = "读取测试进程"
            # 已有身份时只核对原 PID；进程已退出或被复用时不能采样后来启动的 App。
            processes = self.processes or self._fixture_processes(executable)
            if not processes:
                self.report(f"移动界面诊断未采集（{reason}）：未发现已核对路径下的合成测试进程。")
                return
            for pid, command in processes.items():
                if (pid in self.sampled or self.attempts.get(pid, 0) >= MAX_PROCESS_ATTEMPTS
                        or self.sample_attempts >= MAX_SAMPLE_ATTEMPTS):
                    continue
                identity = self.run(
                    ["ps", "-p", pid, "-o", "command=", "-ww"],
                    capture_output=True, text=True, check=True, timeout=5,
                ).stdout.strip()
                if identity != command:
                    continue
                stage = "采集调用栈"
                attempt = self.attempts.get(pid, 0) + 1
                self.attempts[pid] = attempt
                self.sample_attempts += 1
                self.output.mkdir(parents=True, exist_ok=True)
                target = self.output / f"DsmMobile-{pid}-{attempt}.sample.txt"
                # 首次采样失败不记为成功，后续独立触发至多再试一次，并保留各次输出。
                self.run(
                    ["/usr/bin/sample", pid, "3", "10", "-file", str(target)],
                    capture_output=True, text=True, check=True, timeout=45,
                )
                self.sampled.add(pid)
                self.report(f"移动界面诊断已采集（{reason}）：{target.name}")
        except (OSError, subprocess.SubprocessError) as error:
            # 诊断不能改变测试结论；工作流的 pipefail 保留 xcodebuild 原退出码。
            self.report(f"移动界面诊断未采集（{reason}，{stage}）：{type(error).__name__}。原测试结果仍保留。")


class UIHangMonitor:
    """合并待办诊断；只为 XCTest 的启动、空闲和查询阶段设置无输出观察期限。"""

    def __init__(self, sampler, quiet_seconds=QUIET_SECONDS, clock=time.monotonic):
        self.sampler = sampler
        self.quiet_seconds = quiet_seconds
        self.clock = clock
        self.condition = threading.Condition()
        self.closed = False
        self.prepare_pending = None
        self.capture_pending = None
        self.watched = False
        self.quiet_captured = False
        self.last_output = clock()
        self.thread = threading.Thread(target=self._run, name="apple-ui-diagnostics", daemon=True)
        self.thread.start()

    def observe(self, line):
        with self.condition:
            self.last_output = self.clock()
            action = UI_ACTION.search(line)
            if action:
                text = action.group(1).strip()
                if text == b"Launch " + BUNDLE_ID.encode():
                    # 新启动不沿用上一用例的 PID；此时进程可能尚未创建，只预取容器路径。
                    self.prepare_pending = "launch"
                # 普通长业务等待（Waiting ...）、输入、滚动等不属于无输出卡顿证据。
                self.watched = (
                    text.startswith(b"Launch " + BUNDLE_ID.encode())
                    or text.startswith(AUTOMATION_SESSION)
                    or text.startswith(b"Wait for " + BUNDLE_ID.encode() + b" to idle")
                    or text.startswith((b"Find the ", b"Checking existence of ",
                                        b"Requesting snapshot of accessibility hierarchy"))
                )
                self.quiet_captured = False
            if b"Test Case " in line or b"Tear Down" in line or b"** TEST " in line:
                self.watched = False
            if b"Test Case " in line and b" started." in line:
                # 新用例不能承接上一用例尚未开始的诊断；失败后的 teardown 仍可核对原 PID。
                self.capture_pending = None
            if AUTOMATION_SESSION in line:
                self.prepare_pending = "automation"
            if IDLE_TIMEOUT in line:
                self.capture_pending = "界面空闲超时"
            elif any(marker in line for marker in QUERY_FAILURES):
                self.capture_pending = "界面快照查询超时"
            elif any(marker in line for marker in LAUNCH_FAILURES):
                self.capture_pending = "测试应用启动失败"
            self.condition.notify_all()

    def _run(self):
        while True:
            with self.condition:
                quiet = self.clock() - self.last_output
                if self.prepare_pending:
                    operation, reason = "prepare", self.prepare_pending
                    self.prepare_pending = None
                elif self.capture_pending:
                    operation, reason = "capture", self.capture_pending
                    self.capture_pending = None
                elif (not self.closed and self.watched and not self.quiet_captured
                      and quiet >= self.quiet_seconds):
                    self.quiet_captured = True
                    operation, reason = "capture", "启动或界面查询阶段持续无输出"
                elif self.closed:
                    return
                else:
                    delay = max(0.01, self.quiet_seconds - quiet) if self.watched and not self.quiet_captured else None
                    self.condition.wait(timeout=delay)
                    continue
            try:
                if operation == "prepare":
                    self.sampler.prepare(remember_processes=reason == "automation")
                else:
                    self.sampler.capture(reason)
            except Exception as error:
                # 意外诊断异常也不能让转发进程报失败或泄露子命令内容。
                print(f"移动界面诊断未完成：{type(error).__name__}。原测试结果仍保留。",
                      file=sys.stderr, flush=True)

    def close(self):
        with self.condition:
            self.closed = True
            self.condition.notify_all()
        # 仅等待有界的已开始/已合并诊断，保证上传产物前文件写完，不积压每条日志的任务。
        self.thread.join()


def forward_output(source, destination, sampler, quiet_seconds=QUIET_SECONDS):
    monitor = UIHangMonitor(sampler, quiet_seconds=quiet_seconds)
    try:
        for line in source:
            destination.write(line)
            destination.flush()
            monitor.observe(line)
    finally:
        monitor.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    forward_output(sys.stdin.buffer, sys.stdout.buffer, HangSampler(arguments.device, arguments.output))


if __name__ == "__main__":
    main()
