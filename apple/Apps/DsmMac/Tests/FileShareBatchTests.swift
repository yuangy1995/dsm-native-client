import DsmCore
import Vision
import XCTest
@testable import DsmMacExecutable

final class FileShareBatchTests: XCTestCase, @unchecked Sendable {
    func test本机二维码解码内容等于原链接() throws {
        let link = "https://example.invalid/sharing/synthetic?name=%E6%B5%8B%E8%AF%95"
        let image = try XCTUnwrap(FileShareQRCode.image(for: link))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        XCTAssertEqual(request.results?.first?.payloadStringValue, link)
    }

    func test多选逐项创建保留成功和未知结果且去重() async throws {
        let profile = UUID()
        let targets = (0..<3).map { FileItem(profileID: profile, name: "\($0).txt", path: "/synthetic/\($0).txt", kind: .file) }
        let recorder = ShareBatchRecorder()
        let results = await FileShareBatch.create(targets: targets + [targets[0]], password: nil,
            availableOn: nil, expiresOn: nil) { request in
            await recorder.record(request.target.path)
            let status: MutationResultStatus = request.target == targets[0] ? .confirmedSuccess
                : request.target == targets[1] ? .permissionDenied : .submittedButUnverified
            return FileShareLinkCreateOutcome(result: try MutationResult(status: status,
                operation: "shareLinkCreate", submitted: status != .permissionDenied,
                requiresRefresh: status == .submittedButUnverified,
                counts: MutationResultCounts(succeeded: status == .confirmedSuccess ? 1 : 0,
                    failed: status == .permissionDenied ? 1 : 0, unknown: status == .submittedButUnverified ? 1 : 0)),
                confirmedLink: status == .confirmedSuccess ? FileShareLink(id: "synthetic", name: "0.txt",
                    path: request.target.path, url: "https://example.invalid/sharing/synthetic") : nil)
        }
        XCTAssertEqual(results.map(\.status), [.confirmedSuccess, .permissionDenied, .submittedButUnverified])
        XCTAssertEqual(results.compactMap(\.link).count, 1)
        let paths = await recorder.paths
        XCTAssertEqual(paths, targets.map(\.path))
    }

    func test无效日期阻止整批发出请求() async throws {
        let recorder = ShareBatchRecorder()
        let target = FileItem(profileID: UUID(), name: "item", path: "/synthetic/item", kind: .file)
        let results = await FileShareBatch.create(targets: [target], password: nil,
            availableOn: try .init(year: 2026, month: 10, day: 5),
            expiresOn: try .init(year: 2026, month: 10, day: 1)) { request in
                await recorder.record(request.target.path)
                throw CancellationError()
            }
        XCTAssertEqual(results.first?.status, .confirmedFailure)
        let paths = await recorder.paths
        XCTAssertTrue(paths.isEmpty)
    }
}

private actor ShareBatchRecorder {
    var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}
