#!/usr/bin/env python3
"""转发 Xcode 测试输出，并在主线程空闲超时时采样当前模拟器内的合成测试 App。"""

import argparse
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


BUNDLE_ID = "io.github.qwertyuiop1995.dsmnativeclient.mobile"
IDLE_TIMEOUT = b"App event loop idle notification not received"
FIXTURE_ARGUMENTS = {"--ui-fixture", "--ui-files-fixture", "--ui-share-fixture"}


class HangSampler:
    def __init__(self, device, output, run=subprocess.run, report=None):
        self.device = device
        self.output = Path(output)
        self.run = run
        self.report = report or (lambda message: print(message, file=sys.stderr, flush=True))
        self.sampled = set()

    def capture(self):
        stage = "定位测试应用"
        try:
            container = self.run(
                ["xcrun", "simctl", "get_app_container", self.device, BUNDLE_ID, "app"],
                capture_output=True, text=True, check=True, timeout=10,
            ).stdout.strip()
            if not container or not Path(container).is_absolute():
                self.report("移动启动诊断未采集：无法确定当前模拟器的 App 路径。")
                return
            executable = str(Path(container) / "DsmMobile")
            stage = "读取测试进程"
            processes = self.run(
                ["ps", "-axo", "pid=,command="],
                capture_output=True, text=True, check=True, timeout=5,
            ).stdout
            for line in processes.splitlines():
                parts = line.strip().split(None, 1)
                if len(parts) != 2 or not parts[0].isdigit():
                    continue
                pid, command = parts
                if not command.startswith(executable + " "):
                    continue
                arguments = command[len(executable) + 1:].split()
                # 只采集指定模拟器、指定 App 且显式启用合成环境的进程。
                if not FIXTURE_ARGUMENTS.intersection(arguments) or pid in self.sampled:
                    continue
                self.sampled.add(pid)
                stage = "采集调用栈"
                self.output.mkdir(parents=True, exist_ok=True)
                target = self.output / f"DsmMobile-{pid}.sample.txt"
                # sample 的 3 秒只计采样，后续符号解析也需要时间；该预算不延长业务测试。
                self.run(
                    ["/usr/bin/sample", pid, "3", "10", "-file", str(target)],
                    capture_output=True, text=True, check=True, timeout=45,
                )
                self.report(f"移动启动诊断已采集：{target.name}")
        except (OSError, subprocess.SubprocessError) as error:
            # 诊断不能改变测试结论；工作流的 pipefail 保留 xcodebuild 原退出码。
            self.report(f"移动启动诊断未采集（{stage}）：{type(error).__name__}。原测试结果仍保留。")


def forward_output(source, destination, sampler):
    # 采样与输出读取并行，不能让诊断阻塞测试日志或改变测试等待时间。
    with ThreadPoolExecutor(max_workers=1) as executor:
        captures = []
        for line in source:
            destination.write(line)
            destination.flush()
            if IDLE_TIMEOUT in line:
                captures.append(executor.submit(sampler.capture))
        for capture in captures:
            capture.result()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    forward_output(sys.stdin.buffer, sys.stdout.buffer, HangSampler(arguments.device, arguments.output))


if __name__ == "__main__":
    main()
