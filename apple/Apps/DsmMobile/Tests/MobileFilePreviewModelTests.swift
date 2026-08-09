@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor NonCooperativePreviewGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func hasWaiter() -> Bool { !waiters.isEmpty }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FilePreviewServiceStub: MobileFilePreviewServing {
    nonisolated let profileID: UUID
    private var infoByPath: [String: Result<[FileItem], Error>]
    private var infoDelays: [String: UInt64]
    private var infoGates: [String: NonCooperativePreviewGate]
    private(set) var infoCalls: [String] = []
    private(set) var mediaCalls: [(String, String?, Int64?)] = []

    init(
        profileID: UUID,
        infoByPath: [String: Result<[FileItem], Error>] = [:],
        infoDelays: [String: UInt64] = [:],
        infoGates: [String: NonCooperativePreviewGate] = [:]
    ) {
        self.profileID = profileID
        self.infoByPath = infoByPath
        self.infoDelays = infoDelays
        self.infoGates = infoGates
    }

    func getInfo(paths: [String]) async throws -> [FileItem] {
        guard let path = paths.first else { return [] }
        infoCalls.append(path)
        if let gate = infoGates[path] {
            await gate.wait()
        }
        if let delay = infoDelays[path] {
            try? await Task.sleep(nanoseconds: delay)
        }
        return try infoByPath[path]?.get() ?? []
    }

    func mediaStreamSource(
        remotePath: String,
        fileExtension: String?,
        expectedContentLength: Int64?
    ) async throws -> MediaStreamSource {
        mediaCalls.append((remotePath, fileExtension, expectedContentLength))
        return makeMediaSource(expectedContentLength: expectedContentLength)
    }

    func requestedInfoPaths() -> [String] { infoCalls }
    func requestedMediaPaths() -> [(String, String?, Int64?)] { mediaCalls }
}

private actor PreviewRangeReaderStub: MobileSecureRangeReading {
    private let result: Result<MobileSecureRangePayload, Error>

    init(_ result: Result<MobileSecureRangePayload, Error>) {
        self.result = result
    }

    func read(
        source: MediaStreamSource,
        offset: Int64,
        maximumLength: Int,
        ifMatch: String?,
        requiresStrongETag: Bool
    ) async throws -> MobileSecureRangePayload {
        try result.get()
    }
}

private actor GeneratedPreviewRangeReader: MobileSecureRangeReading {
    private var results: [Result<MobileSecureRangePayload, Error>]
    private let delayNanoseconds: UInt64

    init(
        results: [Result<MobileSecureRangePayload, Error>] = [],
        delayNanoseconds: UInt64 = 0
    ) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    func read(
        source: MediaStreamSource,
        offset: Int64,
        maximumLength: Int,
        ifMatch: String?,
        requiresStrongETag: Bool
    ) async throws -> MobileSecureRangePayload {
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if !results.isEmpty { return try results.removeFirst().get() }
        guard let total = source.expectedContentLength, total > offset else {
            throw URLError(.badServerResponse)
        }
        let count = Int(min(Int64(maximumLength), total - offset))
        return MobileSecureRangePayload(
            data: Data(repeating: 0x5A, count: count),
            contentType: nil,
            totalLength: total,
            strongETag: requiresStrongETag || ifMatch != nil ? "\"generated-v1\"" : nil
        )
    }
}

private actor SequencedRangeReaderStub: MobileSecureRangeReading {
    struct Call: Sendable {
        let ifMatch: String?
        let requiresStrongETag: Bool
    }

    private var payloads: [MobileSecureRangePayload]
    private(set) var calls: [Call] = []

    init(payloads: [MobileSecureRangePayload]) {
        self.payloads = payloads
    }

    func read(
        source: MediaStreamSource,
        offset: Int64,
        maximumLength: Int,
        ifMatch: String?,
        requiresStrongETag: Bool
    ) async throws -> MobileSecureRangePayload {
        calls.append(Call(ifMatch: ifMatch, requiresStrongETag: requiresStrongETag))
        guard !payloads.isEmpty else { throw URLError(.badServerResponse) }
        return payloads.removeFirst()
    }

    func recordedCalls() -> [Call] { calls }
}

private final class SyntheticRangeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class MobileFilePreviewModelTests: XCTestCase {
    func test图片预览下载不信任列表大小且成功产物保留到关闭() async throws {
        let fixture = try makeFixture()
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg", size: 99)
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.phase, .ready)
        XCTAssertEqual(fixture.model.state.previewKind, .image)
        let artifact = try XCTUnwrap(fixture.model.state.artifactURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertEqual(mediaCalls.count, 1)
        XCTAssertEqual(mediaCalls[0].2, 99)

        fixture.model.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertEqual(fixture.model.state.phase, .inactive)
    }

    func test文件夹未知大小媒体与不支持类型不会触发下载或Range读取() async throws {
        let fixture = try makeFixture()
        let items = [
            file(fixture.profileID, name: "folder", path: "/folder", kind: .directory),
            file(fixture.profileID, name: "note.txt", path: "/note.txt"),
            file(fixture.profileID, name: "movie.mp4", path: "/movie.mp4"),
            file(fixture.profileID, name: "song.mp3", path: "/song.mp3"),
            file(fixture.profileID, name: "archive.bin", path: "/archive.bin")
        ]
        let service = FilePreviewServiceStub(profileID: fixture.profileID)

        for item in items {
            await fixture.model.open(item, service: service)
        }

        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertTrue(mediaCalls.isEmpty)
    }

    func test已知小文本使用安全Range并在内存解码UTF8() async throws {
        let data = Data("你好，NAS".utf8)
        let reader = PreviewRangeReaderStub(.success(MobileSecureRangePayload(
            data: data,
            contentType: "text/plain",
            totalLength: Int64(data.count),
            strongETag: nil
        )))
        let fixture = try makeFixture(rangeReader: reader)
        let item = file(fixture.profileID, name: "note.txt", path: "/note.txt", size: Int64(data.count))
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.phase, .ready)
        XCTAssertEqual(fixture.model.state.content, .text("你好，NAS"))
        XCTAssertNil(fixture.model.state.artifactURL)
        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertEqual(mediaCalls.count, 1)
    }

    func test文本必须使用刷新后的已知大小() async throws {
        let data = Data("cached size must not be trusted".utf8)
        let reader = PreviewRangeReaderStub(.success(MobileSecureRangePayload(
            data: data,
            contentType: "text/plain",
            totalLength: Int64(data.count),
            strongETag: nil
        )))
        let fixture = try makeFixture(rangeReader: reader)
        let item = file(fixture.profileID, name: "note.txt", path: "/note.txt", size: Int64(data.count))
        let service = FilePreviewServiceStub(profileID: fixture.profileID)

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.content, .textSizeUnknown)
        XCTAssertEqual(fixture.model.state.phase, .ready)
        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertTrue(mediaCalls.isEmpty)
    }

    func test文本支持带BOM的UTF16大小端() async throws {
        let fixtures: [(Data, String)] = [
            (Data([0xFF, 0xFE, 0x60, 0x4F, 0x7D, 0x59]), "你好"),
            (Data([0xFE, 0xFF, 0x4F, 0x60, 0x59, 0x7D]), "你好")
        ]
        for (data, expected) in fixtures {
            let reader = PreviewRangeReaderStub(.success(MobileSecureRangePayload(
                data: data,
                contentType: "text/plain",
                totalLength: Int64(data.count),
                strongETag: nil
            )))
            let fixture = try makeFixture(rangeReader: reader)
            let item = file(
                fixture.profileID,
                name: "note.txt",
                path: "/note-\(UUID().uuidString).txt",
                size: Int64(data.count)
            )
            let service = FilePreviewServiceStub(
                profileID: fixture.profileID,
                infoByPath: [item.path: .success([item])]
            )

            await fixture.model.open(item, service: service)

            XCTAssertEqual(fixture.model.state.content, .text(expected))
        }
    }

    func test超过1MiB文本不请求媒体源也不落临时文件() async throws {
        let fixture = try makeFixture()
        let item = file(
            fixture.profileID,
            name: "large.txt",
            path: "/large.txt",
            size: MobileFilePreviewModel.maximumTextBytes + 1
        )
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.content, .textTooLarge)
        XCTAssertEqual(fixture.model.state.phase, .ready)
        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertTrue(mediaCalls.isEmpty)
        XCTAssertNil(fixture.model.state.artifactURL)
    }

    func test白名单媒体只准备内存流源且不下载整文件() async throws {
        let fixture = try makeFixture()
        let item = file(fixture.profileID, name: "movie.mp4", path: "/movie.mp4", size: 8_000_000)
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.content, .media)
        XCTAssertEqual(fixture.model.state.phase, .ready)
        XCTAssertNotNil(fixture.model.mediaSource)
        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertEqual(mediaCalls.count, 1)
        XCTAssertNil(fixture.model.state.artifactURL)
    }

    func test安全Range接受强ETag并在后续请求发送IfMatch() async throws {
        let reader = MobileSecureRangeReader(protocolClasses: [SyntheticRangeURLProtocol.self])
        var observedIfMatch: String?
        SyntheticRangeURLProtocol.handler = { request in
            observedIfMatch = request.value(forHTTPHeaderField: "If-Match")
            return (try syntheticResponse(status: 206, headers: [
                "Content-Range": "bytes 4-7/8",
                "Content-Type": "audio/mp4",
                "ETag": "\"version-1\""
            ]), Data([4, 5, 6, 7]))
        }
        defer { SyntheticRangeURLProtocol.handler = nil }

        let payload = try await reader.read(
            source: makeMediaSource(expectedContentLength: 8),
            offset: 4,
            maximumLength: 4,
            ifMatch: "\"version-1\"",
            requiresStrongETag: true
        )

        XCTAssertEqual(observedIfMatch, "\"version-1\"")
        XCTAssertEqual(payload.strongETag, "\"version-1\"")
    }

    func test媒体Range协调器首段锁定强ETag且后续段绑定IfMatch() async throws {
        let tag = "\"version-1\""
        let reader = SequencedRangeReaderStub(payloads: [
            MobileSecureRangePayload(
                data: Data([0, 1, 2, 3]),
                contentType: "video/mp4",
                totalLength: 8,
                strongETag: tag
            ),
            MobileSecureRangePayload(
                data: Data([4, 5, 6, 7]),
                contentType: "video/mp4",
                totalLength: 8,
                strongETag: tag
            )
        ])
        let coordinator = MobileMediaRangeCoordinator(
            source: makeMediaSource(expectedContentLength: 8),
            reader: reader
        )

        _ = try await coordinator.read(offset: 0, maximumLength: 4)
        _ = try await coordinator.read(offset: 4, maximumLength: 4)

        let calls = await reader.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].requiresStrongETag)
        XCTAssertNil(calls[0].ifMatch)
        XCTAssertEqual(calls[1].ifMatch, tag)
        XCTAssertTrue(calls[1].requiresStrongETag)
    }

    func test媒体首读覆盖完整文件后非零Seek仍绑定首次强ETag() async throws {
        let tag = "\"complete-first-v1\""
        let reader = SequencedRangeReaderStub(payloads: [
            MobileSecureRangePayload(
                data: Data([0, 1, 2, 3]),
                contentType: "video/mp4",
                totalLength: 4,
                strongETag: tag
            ),
            MobileSecureRangePayload(
                data: Data([1, 2, 3]),
                contentType: "video/mp4",
                totalLength: 4,
                strongETag: tag
            )
        ])
        let coordinator = MobileMediaRangeCoordinator(
            source: makeMediaSource(expectedContentLength: 4),
            reader: reader
        )

        _ = try await coordinator.read(offset: 0, maximumLength: 4)
        _ = try await coordinator.read(offset: 1, maximumLength: 3)

        let calls = await reader.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[0].ifMatch)
        XCTAssertTrue(calls[0].requiresStrongETag)
        XCTAssertEqual(calls[1].ifMatch, tag)
        XCTAssertTrue(calls[1].requiresStrongETag)
    }

    func test安全Range明确拒绝负Offset与非正Length且不发请求() async throws {
        let reader = MobileSecureRangeReader(protocolClasses: [SyntheticRangeURLProtocol.self])
        var requestCount = 0
        SyntheticRangeURLProtocol.handler = { _ in
            requestCount += 1
            return (try syntheticResponse(status: 206, headers: [
                "Content-Range": "bytes 0-0/8"
            ]), Data([0]))
        }
        defer { SyntheticRangeURLProtocol.handler = nil }

        for input in [(-1 as Int64, 1), (0, 0), (0, -1)] {
            do {
                _ = try await reader.read(
                    source: makeMediaSource(expectedContentLength: 8),
                    offset: input.0,
                    maximumLength: input.1,
                    ifMatch: nil,
                    requiresStrongETag: false
                )
                XCTFail("非法 Range 参数必须明确失败")
            } catch {}
        }
        XCTAssertEqual(requestCount, 0)
    }

    func test安全Range拒绝弱ETag与缺失ETag() async throws {
        let reader = MobileSecureRangeReader(protocolClasses: [SyntheticRangeURLProtocol.self])
        for etag in ["W/\"version-1\"", nil] as [String?] {
            SyntheticRangeURLProtocol.handler = { _ in
                var headers = ["Content-Range": "bytes 0-3/8"]
                headers["ETag"] = etag
                return (try syntheticResponse(status: 206, headers: headers), Data([0, 1, 2, 3]))
            }
            do {
                _ = try await reader.read(
                    source: makeMediaSource(expectedContentLength: 8),
                    offset: 0,
                    maximumLength: 4,
                    ifMatch: nil,
                    requiresStrongETag: true
                )
                XCTFail("应拒绝弱或缺失的 ETag")
            } catch {}
        }
        SyntheticRangeURLProtocol.handler = nil
    }

    func test安全Range拒绝412与版本变化() async throws {
        let reader = MobileSecureRangeReader(protocolClasses: [SyntheticRangeURLProtocol.self])
        for fixture in [(412, "\"version-1\""), (206, "\"version-2\"")] {
            SyntheticRangeURLProtocol.handler = { _ in
                (try syntheticResponse(status: fixture.0, headers: [
                    "Content-Range": "bytes 4-7/8",
                    "ETag": fixture.1
                ]), Data([4, 5, 6, 7]))
            }
            do {
                _ = try await reader.read(
                    source: makeMediaSource(expectedContentLength: 8),
                    offset: 4,
                    maximumLength: 4,
                    ifMatch: "\"version-1\"",
                    requiresStrongETag: true
                )
                XCTFail("应拒绝 412 或版本变化")
            } catch {}
        }
        SyntheticRangeURLProtocol.handler = nil
    }

    func test安全Range拒绝与ContentRange冲突的ContentLength() async throws {
        let reader = MobileSecureRangeReader(protocolClasses: [SyntheticRangeURLProtocol.self])
        SyntheticRangeURLProtocol.handler = { _ in
            (try syntheticResponse(status: 206, headers: [
                "Content-Range": "bytes 0-3/8",
                "Content-Length": "5"
            ]), Data([0, 1, 2, 3]))
        }
        defer { SyntheticRangeURLProtocol.handler = nil }

        do {
            _ = try await reader.read(
                source: makeMediaSource(expectedContentLength: 8),
                offset: 0,
                maximumLength: 4,
                ifMatch: nil,
                requiresStrongETag: false
            )
            XCTFail("应拒绝互相冲突的 Content-Length")
        } catch {}
    }

    func testQuickLook多段Range首段锁定强ETag且后续发送IfMatch() async throws {
        let chunk = MobileSecureRangeReader.maximumRangeLength
        let total = Int64(chunk + 1)
        let tag = "\"quicklook-v1\""
        let reader = SequencedRangeReaderStub(payloads: [
            MobileSecureRangePayload(
                data: Data(repeating: 1, count: chunk),
                contentType: "image/jpeg",
                totalLength: total,
                strongETag: tag
            ),
            MobileSecureRangePayload(
                data: Data([2]),
                contentType: "image/jpeg",
                totalLength: total,
                strongETag: tag
            )
        ])
        let fixture = try makeFixture(rangeReader: reader)
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg", size: total)
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.phase, .ready)
        let artifact = try XCTUnwrap(fixture.model.state.artifactURL)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: artifact.path)[.size] as? NSNumber,
            NSNumber(value: total)
        )
        let calls = await reader.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].requiresStrongETag)
        XCTAssertNil(calls[0].ifMatch)
        XCTAssertEqual(calls[1].ifMatch, tag)
    }

    func testQuickLook未知或超过128MiB时零内容请求() async throws {
        let fixture = try makeFixture()
        let unknown = file(fixture.profileID, name: "unknown.pdf", path: "/unknown.pdf")
        let oversized = file(
            fixture.profileID,
            name: "large.pdf",
            path: "/large.pdf",
            size: MobileFilePreviewModel.maximumQuickLookBytes + 1
        )
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [
                unknown.path: .success([unknown]),
                oversized.path: .success([oversized])
            ]
        )

        for item in [unknown, oversized] {
            await fixture.model.open(item, service: service)
            XCTAssertEqual(fixture.model.state.phase, .detailsOnly)
            XCTAssertNil(fixture.model.state.artifactURL)
        }
        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertTrue(mediaCalls.isEmpty)
    }

    func test迟到的A不会覆盖B或删除B的产物() async throws {
        let fixture = try makeFixture()
        let first = file(fixture.profileID, name: "a.jpg", path: "/a.jpg", size: 7)
        let second = file(fixture.profileID, name: "b.pdf", path: "/b.pdf", size: 7)
        let gate = NonCooperativePreviewGate()
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [
                first.path: .success([first]),
                second.path: .success([second])
            ],
            infoGates: [first.path: gate]
        )

        let firstTask = Task { await fixture.model.open(first, service: service) }
        while !(await gate.hasWaiter()) { await Task.yield() }
        await fixture.model.open(second, service: service)
        let secondArtifact = try XCTUnwrap(fixture.model.state.artifactURL)
        XCTAssertEqual(fixture.model.state.phase, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondArtifact.path))

        await gate.release()
        await firstTask.value

        XCTAssertEqual(fixture.model.state.selectedItem?.path, second.path)
        XCTAssertEqual(fixture.model.state.previewKind, .pdf)
        XCTAssertEqual(fixture.model.state.phase, .ready)
        XCTAssertEqual(fixture.model.state.artifactURL, secondArtifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondArtifact.path))
    }

    func test切换Profile会取消并清理成功产物() async throws {
        let fixture = try makeFixture()
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg", size: 7)
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )
        await fixture.model.open(item, service: service)
        let artifact = try XCTUnwrap(fixture.model.state.artifactURL)

        let otherProfile = UUID()
        fixture.model.activate(profileID: otherProfile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertEqual(fixture.model.state.profileID, otherProfile)
        XCTAssertNil(fixture.model.state.selectedItem)
        XCTAssertNil(fixture.model.state.artifactURL)
    }

    func test模型未显式关闭即释放时会清理自身持有目录() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileFilePreviewDeinitTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let item = file(profileID, name: "photo.jpg", path: "/photo.jpg", size: 7)
        let service = FilePreviewServiceStub(
            profileID: profileID,
            infoByPath: [item.path: .success([item])]
        )
        var model: MobileFilePreviewModel? = MobileFilePreviewModel(
            rootURL: root,
            rangeReader: GeneratedPreviewRangeReader()
        )
        model?.activate(profileID: profileID)
        await model?.open(item, service: service)
        let artifact = try XCTUnwrap(model?.state.artifactURL)
        let directory = artifact.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        weak var weakModel = model

        model = nil

        XCTAssertNil(weakModel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func test每次操作使用不同目录与随机UUID文件名() async throws {
        let fixture = try makeFixture()
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg", size: 7)
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)
        let first = try XCTUnwrap(fixture.model.state.artifactURL)
        await fixture.model.retry(service: service)
        let second = try XCTUnwrap(fixture.model.state.artifactURL)

        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        for url in [first, second] {
            _ = try XCTUnwrap(UUID(uuidString: url.deletingPathExtension().lastPathComponent))
            XCTAssertFalse(url.lastPathComponent.contains(item.name))
            XCTAssertEqual(url.pathExtension, "jpg")
        }
    }

    func test安全文件名不会逃逸独占目录() async throws {
        let fixture = try makeFixture()
        let item = file(
            fixture.profileID,
            name: "../..\\unsafe:\u{0000}.jpg",
            path: "/unsafe.jpg",
            size: 7
        )
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)

        let artifact = try XCTUnwrap(fixture.model.state.artifactURL)
        XCTAssertEqual(
            artifact.deletingLastPathComponent().deletingLastPathComponent(),
            fixture.rootURL
        )
        XCTAssertFalse(artifact.lastPathComponent.contains("/"))
        XCTAssertFalse(artifact.lastPathComponent.contains("\\"))
        XCTAssertFalse(artifact.lastPathComponent.contains(":"))
    }

    func test超长英文和中文文件名含UUID前缀后不超过255字节并保留扩展名() async throws {
        let fixture = try makeFixture()
        let items = [
            file(
                fixture.profileID,
                name: String(repeating: "a", count: 400) + ".jpg",
                path: "/long-a.jpg",
                size: 7
            ),
            file(
                fixture.profileID,
                name: String(repeating: "预览文件", count: 100) + ".pdf",
                path: "/long-zh.pdf",
                size: 7
            )
        ]
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: Dictionary(uniqueKeysWithValues: items.map { ($0.path, .success([$0])) })
        )

        for item in items {
            await fixture.model.open(item, service: service)
            let artifact = try XCTUnwrap(fixture.model.state.artifactURL)
            XCTAssertLessThanOrEqual(artifact.lastPathComponent.utf8.count, 255)
            XCTAssertEqual(artifact.pathExtension, item.fileExtension)
        }
    }

    func test详情刷新失败保留列表详情但不发起QuickLook内容请求() async throws {
        let fixture = try makeFixture()
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg", size: 7)
        let error = AppError(
            category: .networkUnavailable,
            isRetryable: true,
            safeUserMessage: "synthetic"
        )
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .failure(error)]
        )

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.details, item)
        XCTAssertEqual(fixture.model.state.detailsFailure, .networkUnavailable)
        XCTAssertEqual(fixture.model.state.phase, .detailsOnly)
        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertTrue(mediaCalls.isEmpty)
    }

    func testRange错误分类且重试成功() async throws {
        let error = AppError(
            category: .permissionDenied,
            isRetryable: false,
            safeUserMessage: "synthetic"
        )
        let successful = MobileSecureRangePayload(
            data: Data(repeating: 1, count: 7),
            contentType: "image/jpeg",
            totalLength: 7,
            strongETag: nil
        )
        let reader = GeneratedPreviewRangeReader(results: [.failure(error), .success(successful)])
        let fixture = try makeFixture(rangeReader: reader)
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg", size: 7)
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)
        XCTAssertEqual(fixture.model.state.phase, .failed)
        XCTAssertEqual(fixture.model.state.previewFailure, .permissionDenied)
        XCTAssertNil(fixture.model.state.artifactURL)

        await fixture.model.retry(service: service)
        XCTAssertEqual(fixture.model.state.phase, .ready)
        XCTAssertNil(fixture.model.state.previewFailure)
        XCTAssertNotNil(fixture.model.state.artifactURL)
    }

    func test服务主动取消详情刷新会保留列表详情且不读取QuickLook内容() async throws {
        let fixture = try makeFixture()
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg")
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .failure(CancellationError())]
        )

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.details, item)
        XCTAssertEqual(fixture.model.state.detailsFailure, .cancelled)
        XCTAssertEqual(fixture.model.state.phase, .detailsOnly)
        XCTAssertNil(fixture.model.state.artifactURL)
        let mediaCalls = await service.requestedMediaPaths()
        XCTAssertTrue(mediaCalls.isEmpty)
    }

    func test服务主动取消Range会清理产物与进度并进入Cancelled() async throws {
        let fixture = try makeFixture(
            rangeReader: GeneratedPreviewRangeReader(results: [.failure(CancellationError())])
        )
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg", size: 7)
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        await fixture.model.open(item, service: service)

        XCTAssertEqual(fixture.model.state.phase, .cancelled)
        XCTAssertEqual(fixture.model.state.previewFailure, .cancelled)
        XCTAssertNil(fixture.model.state.artifactURL)
        XCTAssertNil(fixture.model.state.progress)
    }

    func test取消迟到Range不会恢复为Ready() async throws {
        let fixture = try makeFixture(
            rangeReader: GeneratedPreviewRangeReader(delayNanoseconds: 150_000_000)
        )
        let item = file(fixture.profileID, name: "photo.jpg", path: "/photo.jpg", size: 7)
        let service = FilePreviewServiceStub(
            profileID: fixture.profileID,
            infoByPath: [item.path: .success([item])]
        )

        let task = Task { await fixture.model.open(item, service: service) }
        while fixture.model.state.phase != .loadingPreview {
            await Task.yield()
        }
        fixture.model.cancel()
        await task.value

        XCTAssertEqual(fixture.model.state.phase, .cancelled)
        XCTAssertEqual(fixture.model.state.previewFailure, .cancelled)
        XCTAssertNil(fixture.model.state.artifactURL)
    }

    private func makeFixture(
        rangeReader: any MobileSecureRangeReading = GeneratedPreviewRangeReader()
    ) throws -> (model: MobileFilePreviewModel, rootURL: URL, profileID: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileFilePreviewTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let model = MobileFilePreviewModel(rootURL: root, rangeReader: rangeReader)
        model.activate(profileID: profileID)
        return (model, root, profileID)
    }

    private func file(
        _ profileID: UUID,
        name: String,
        path: String,
        kind: FileKind = .file,
        size: Int64? = nil
    ) -> FileItem {
        FileItem(
            profileID: profileID,
            name: name,
            path: path,
            kind: kind,
            sizeBytes: size
        )
    }
}

private func makeMediaSource(expectedContentLength: Int64?) -> MediaStreamSource {
    MediaStreamSource(
        request: URLRequest(url: URL(string: "https://nas.invalid/file")!),
        fileExtension: "mp4",
        expectedContentLength: expectedContentLength,
        expectedHost: "nas.invalid",
        pinnedCertificateSHA256: nil
    )
}

private func syntheticResponse(
    status: Int,
    headers: [String: String]
) throws -> HTTPURLResponse {
    try XCTUnwrap(HTTPURLResponse(
        url: URL(string: "https://nas.invalid/file")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    ))
}
