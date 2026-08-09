@testable import DsmMobile
import XCTest

private actor MutationSubmissionRecorder {
    private(set) var targets: [String] = []

    func submit(_ target: String, delay: Duration = .milliseconds(80)) async throws -> String {
        targets.append(target)
        try await Task.sleep(for: delay)
        return target
    }

    func count() -> Int { targets.count }
}

final class MobileMutationCoordinatorTests: XCTestCase {
    func test同一Profile操作和目标双击只提交一次() async throws {
        let coordinator = MobileMutationCoordinator()
        let recorder = MutationSubmissionRecorder()
        let profileID = UUID()

        let first = Task {
            try await coordinator.perform(
                profileID: profileID,
                operation: "upload",
                stableTarget: "folder/file"
            ) {
                try await recorder.submit("folder/file")
            }
        }
        try await waitUntil { await recorder.count() == 1 }
        let second = try await coordinator.perform(
            profileID: profileID,
            operation: "upload",
            stableTarget: "folder/file"
        ) {
            try await recorder.submit("folder/file")
        }

        if case .duplicateInFlight = second {
            // 预期路径。
        } else {
            XCTFail("重复目标不应再次提交")
        }
        _ = try await first.value
        let submissionCount = await recorder.count()
        XCTAssertEqual(submissionCount, 1)
    }

    func test不同目标可分别提交() async throws {
        let coordinator = MobileMutationCoordinator()
        let recorder = MutationSubmissionRecorder()
        let profileID = UUID()

        async let first = coordinator.perform(
            profileID: profileID,
            operation: "upload",
            stableTarget: "folder/a"
        ) {
            try await recorder.submit("folder/a", delay: .milliseconds(10))
        }
        async let second = coordinator.perform(
            profileID: profileID,
            operation: "upload",
            stableTarget: "folder/b"
        ) {
            try await recorder.submit("folder/b", delay: .milliseconds(10))
        }
        _ = try await (first, second)

        let targets = await recorder.targets
        XCTAssertEqual(Set(targets), Set(["folder/a", "folder/b"]))
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("等待条件超时")
}
